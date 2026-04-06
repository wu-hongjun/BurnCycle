import Foundation
import IOKit
import IOKit.ps
import Combine

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published var percentage: Int = 0
    @Published var isPluggedIn: Bool = false
    @Published var isCharging: Bool = false
    @Published var cycleCount: Int = 0
    @Published var healthPercent: Int = 0
    @Published var chargerWatts: Int = 0

    private var timer: Timer?

    init() {
        update()
    }

    func startMonitoring() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
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
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return
        }

        if let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
            percentage = capacity
        }
        if let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
            isPluggedIn = (powerSource == kIOPSACPowerValue)
        }
        if let charging = desc[kIOPSIsChargingKey] as? Bool {
            isCharging = charging
        }

        // Read cycle count and health from AppleSmartBattery
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }

        if let cycles = dict["CycleCount"] as? Int {
            cycleCount = cycles
        }
        if let adapter = dict["AdapterDetails"] as? [String: Any],
           let watts = adapter["Watts"] as? Int {
            chargerWatts = watts
        } else {
            chargerWatts = 0
        }

        // Read Maximum Capacity % from system_profiler (matches "About This Mac")
        if healthPercent == 0 {
            Task.detached {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                proc.arguments = ["SPPowerDataType"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                try? proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8),
                   let range = output.range(of: #"Maximum Capacity:\s+(\d+)%"#, options: .regularExpression) {
                    let match = output[range]
                    if let numRange = match.range(of: #"\d+"#, options: .regularExpression),
                       let value = Int(match[numRange]) {
                        await MainActor.run { [weak self] in
                            self?.healthPercent = value
                        }
                    }
                }
            }
        }
    }
}
