import Foundation
import IOKit

// MARK: - IOReport private API declarations (used by mactop/asitop, no sudo needed)

@_silgen_name("IOReportCopyChannelsInGroup")
func IOReportCopyChannelsInGroup(_ group: CFString, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> CFDictionary?

@_silgen_name("IOReportCreateSubscription")
func IOReportCreateSubscription(_ a: UnsafeMutableRawPointer?, _ channels: CFDictionary, _ b: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, _ c: UInt64, _ d: UnsafeMutablePointer<CFTypeRef?>?) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOReportCreateSamples")
func IOReportCreateSamples(_ subscription: CFTypeRef, _ a: CFTypeRef?, _ b: UnsafeMutablePointer<CFTypeRef?>?) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportGetChannelCount")
func IOReportGetChannelCount(_ channels: CFDictionary) -> Int

@_silgen_name("IOReportChannelGetGroup")
func IOReportChannelGetGroup(_ channel: CFDictionary) -> Unmanaged<CFString>

@_silgen_name("IOReportChannelGetSubGroup")
func IOReportChannelGetSubGroup(_ channel: CFDictionary) -> Unmanaged<CFString>

@_silgen_name("IOReportSimpleGetIntegerValue")
func IOReportSimpleGetIntegerValue(_ channel: CFDictionary, _ a: UnsafeMutablePointer<Int32>?) -> Int64

@_silgen_name("IOReportChannelGetChannelName")
func IOReportChannelGetChannelName(_ channel: CFDictionary) -> Unmanaged<CFString>

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var gpuUsage: Double = 0
    @Published var powerWatts: Double = 0

    private var timer: Timer?
    private var previousCPUInfo: host_cpu_load_info?

    // IOReport GPU state
    private var gpuSubscription: CFTypeRef?
    private var previousGPUSample: CFDictionary?

    init() {
        previousCPUInfo = readCPUTicks()
        setupGPUReport()
        update()
    }

    func startMonitoring() {
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
            cpuUsage = ((userDelta + systemDelta + niceDelta) / totalDelta) * 100
        }

        previousCPUInfo = current
    }

    private func readCPUTicks() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var cpuLoadInfo = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }

        return result == KERN_SUCCESS ? cpuLoadInfo : nil
    }

    // MARK: - GPU Usage via IOReport (same as mactop/asitop)

    private func setupGPUReport() {
        guard let channels = IOReportCopyChannelsInGroup("GPU" as CFString, nil, 0, 0, 0) else { return }

        var subRef: CFTypeRef?
        guard let subscription = IOReportCreateSubscription(nil, channels, nil, 0, &subRef),
              let sub = subRef else { return }

        let _ = subscription // retained by subRef
        gpuSubscription = sub

        // Take initial sample as baseline
        if let sample = IOReportCreateSamples(sub, nil, nil) {
            previousGPUSample = sample.takeRetainedValue()
        }
    }

    private func updateGPU() {
        guard let sub = gpuSubscription,
              let prevSample = previousGPUSample else {
            // Fallback to PerformanceStatistics if IOReport unavailable
            updateGPUFallback()
            return
        }

        guard let currentSampleRef = IOReportCreateSamples(sub, nil, nil) else { return }
        let currentSample = currentSampleRef.takeRetainedValue()
        defer { previousGPUSample = currentSample }

        // Delta between samples gives us time-weighted utilization
        guard let prevItems = (prevSample as NSDictionary)["IOReportChannels"] as? [NSDictionary],
              let currItems = (currentSample as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            updateGPUFallback()
            return
        }

        var totalActive: Int64 = 0
        var totalIdle: Int64 = 0

        for i in 0..<min(prevItems.count, currItems.count) {
            let prev = prevItems[i] as CFDictionary
            let curr = currItems[i] as CFDictionary

            let group = IOReportChannelGetGroup(curr).takeUnretainedValue() as String
            guard group == "GPU" else { continue }

            let subgroup = IOReportChannelGetSubGroup(curr).takeUnretainedValue() as String

            let prevVal = IOReportSimpleGetIntegerValue(prev, nil)
            let currVal = IOReportSimpleGetIntegerValue(curr, nil)
            let delta = currVal - prevVal

            if subgroup.contains("Active") || subgroup.contains("Busy") {
                totalActive += delta
            } else if subgroup.contains("Idle") || subgroup.contains("Off") {
                totalIdle += delta
            }
        }

        let total = totalActive + totalIdle
        if total > 0 {
            gpuUsage = Double(totalActive) / Double(total) * 100
        }
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
