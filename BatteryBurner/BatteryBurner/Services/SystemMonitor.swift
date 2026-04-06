import Foundation
import IOKit

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0 // 0-100
    @Published var gpuUsage: Double = 0 // 0-100
    @Published var powerWatts: Double = 0 // battery power draw in watts

    private var timer: Timer?
    private var previousCPUInfo: host_cpu_load_info?

    init() {
        previousCPUInfo = readCPUTicks()
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

    // MARK: - GPU Usage via IOKit AGXAccelerator

    private func updateGPU() {
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
            // Amperage may be stored as unsigned-wrapped negative (e.g. 18446744073709547277 = -4339)
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
