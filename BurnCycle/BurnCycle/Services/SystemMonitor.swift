import Foundation
import IOKit

// MARK: - IOReport private API (matched to mactop ioreport.m declarations)

@_silgen_name("IOReportCopyChannelsInGroup")
func IOReportCopyChannelsInGroup(_ group: CFString, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> CFMutableDictionary?

@_silgen_name("IOReportCreateSubscription")
func IOReportCreateSubscription(_ a: UnsafeMutableRawPointer?, _ channels: CFMutableDictionary, _ out: UnsafeMutablePointer<CFMutableDictionary?>?, _ d: UInt64, _ e: CFTypeRef?) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOReportCreateSamples")
func IOReportCreateSamples(_ subscription: CFTypeRef, _ channels: CFMutableDictionary?, _ unused: CFTypeRef?) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportCreateSamplesDelta")
func IOReportCreateSamplesDelta(_ prev: CFDictionary, _ curr: CFDictionary, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportChannelGetGroup")
func IOReportChannelGetGroup(_ channel: CFDictionary) -> Unmanaged<CFString>

@_silgen_name("IOReportChannelGetSubGroup")
func IOReportChannelGetSubGroup(_ channel: CFDictionary) -> Unmanaged<CFString>

@_silgen_name("IOReportChannelGetChannelName")
func IOReportChannelGetChannelName(_ channel: CFDictionary) -> Unmanaged<CFString>

@_silgen_name("IOReportStateGetCount")
func IOReportStateGetCount(_ channel: CFDictionary) -> Int32

@_silgen_name("IOReportStateGetNameForIndex")
func IOReportStateGetNameForIndex(_ channel: CFDictionary, _ index: Int32) -> Unmanaged<CFString>?

@_silgen_name("IOReportStateGetResidency")
func IOReportStateGetResidency(_ channel: CFDictionary, _ index: Int32) -> Int64

// MARK: - SystemMonitor

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var gpuUsage: Double = 0
    @Published var powerWatts: Double = 0

    private var timer: Timer?
    private var previousCPUInfo: host_cpu_load_info?
    private let hostPort = mach_host_self()

    // IOReport GPU state
    private var gpuSubscription: CFTypeRef?
    private var gpuChannels: CFMutableDictionary?
    private var previousGPUSample: CFDictionary?

    init() {
        previousCPUInfo = readCPUTicks()
        setupGPUReport()
    }

    func startMonitoring() {
        // Take initial GPU sample so first delta works
        if let sub = gpuSubscription, let channels = gpuChannels,
           let sampleRef = IOReportCreateSamples(sub, channels, nil) {
            previousGPUSample = sampleRef.takeRetainedValue()
        }
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.update()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func update() {
        updateCPU()
        updateGPU()
        updatePower()
    }

    // MARK: - CPU Usage via mach host_statistics

    private func updateCPU() {
        guard let current = readCPUTicks(), let previous = previousCPUInfo else {
            previousCPUInfo = readCPUTicks()
            return
        }

        let userDelta = Double(current.cpu_ticks.0 - previous.cpu_ticks.0)
        let systemDelta = Double(current.cpu_ticks.1 - previous.cpu_ticks.1)
        let idleDelta = Double(current.cpu_ticks.2 - previous.cpu_ticks.2)
        let niceDelta = Double(current.cpu_ticks.3 - previous.cpu_ticks.3)

        let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
        if totalDelta > 0 {
            cpuUsage = min(100, max(0, ((userDelta + systemDelta + niceDelta) / totalDelta) * 100))
        }

        previousCPUInfo = current
    }

    private func readCPUTicks() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var cpuLoadInfo = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }

        return result == KERN_SUCCESS ? cpuLoadInfo : nil
    }

    // MARK: - GPU Usage via IOReport (exact mactop approach)

    private func setupGPUReport() {
        guard let gpuChan = IOReportCopyChannelsInGroup("GPU Stats" as CFString, nil, 0, 0, 0) else { return }
        gpuChannels = gpuChan

        // Subscription handle comes from the return value (not 5th param)
        // 3rd param is an out-dictionary (subsystem), must be non-nil
        var subsystem: CFMutableDictionary?
        guard let subUnmanaged = IOReportCreateSubscription(nil, gpuChan, &subsystem, 0, nil) else { return }
        gpuSubscription = subUnmanaged.takeRetainedValue()
    }

    private func updateGPU() {
        guard let sub = gpuSubscription, let channels = gpuChannels else {
            updateGPUFallback()
            return
        }

        // Take current sample (pass channels as 2nd arg, like mactop)
        guard let sampleRef = IOReportCreateSamples(sub, channels, nil) else { return }
        let currentSample = sampleRef.takeRetainedValue()

        defer { previousGPUSample = currentSample }

        // Need a previous sample to compute delta
        guard let prevSample = previousGPUSample else { return }

        // Compute delta between previous and current sample
        guard let deltaRef = IOReportCreateSamplesDelta(prevSample, currentSample, nil) else { return }
        let delta = deltaRef.takeRetainedValue()

        // Parse delta using CFDictionary/CFArray APIs (not NSDictionary cast)
        guard let channelsPtr = CFDictionaryGetValue(delta, Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()) else {
            updateGPUFallback()
            return
        }
        let channelArray = unsafeBitCast(channelsPtr, to: CFArray.self)
        let count = CFArrayGetCount(channelArray)

        for i in 0..<count {
            guard let itemPtr = CFArrayGetValueAtIndex(channelArray, i) else { continue }
            let itemCF = unsafeBitCast(itemPtr, to: CFDictionary.self)

            let group = IOReportChannelGetGroup(itemCF).takeUnretainedValue() as String
            guard group == "GPU Stats" else { continue }

            let subgroup = IOReportChannelGetSubGroup(itemCF).takeUnretainedValue() as String
            guard subgroup == "GPU Performance States" else { continue }

            let channel = IOReportChannelGetChannelName(itemCF).takeUnretainedValue() as String
            guard channel == "GPUPH" else { continue }

            // Found GPUPH — compute active vs total residency per P-state
            let stateCount = IOReportStateGetCount(itemCF)
            var totalTime: Int64 = 0
            var activeTime: Int64 = 0

            for s in 0..<stateCount {
                let residency = IOReportStateGetResidency(itemCF, s)
                totalTime += residency

                if let nameRef = IOReportStateGetNameForIndex(itemCF, s) {
                    let name = nameRef.takeUnretainedValue() as String
                    if name != "OFF" && name != "IDLE" && name != "DOWN" {
                        activeTime += residency
                    }
                }
            }

            if totalTime > 0 {
                gpuUsage = min(100, max(0, Double(activeTime) / Double(totalTime) * 100))
            }
            return
        }

        updateGPUFallback()
    }

    private func updateGPUFallback() {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AGXAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perfStats = dict["PerformanceStatistics"] as? [String: Any],
                  let utilization = perfStats["Device Utilization %"] as? Int else { continue }

            gpuUsage = Double(utilization)
            return
        }
    }

    // MARK: - Battery power draw via IOKit

    private func updatePower() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return
        }

        if let voltage = dict["Voltage"] as? Int {
            let amperage: Int64
            if let raw = dict["Amperage"] as? Int64 {
                amperage = raw
            } else if let raw = dict["Amperage"] as? Int {
                amperage = Int64(bitPattern: UInt64(bitPattern: Int64(raw)))
            } else {
                return
            }
            let watts = abs(Double(amperage) * Double(voltage)) / 1_000_000
            powerWatts = (watts * 10).rounded() / 10
        }
    }
}
