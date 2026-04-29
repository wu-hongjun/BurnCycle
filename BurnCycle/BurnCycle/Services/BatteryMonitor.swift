import Foundation
import IOKit
import IOKit.ps

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published var percentage: Int = 0
    @Published var isPluggedIn: Bool = false
    @Published var isCharging: Bool = false
    @Published var cycleCount: Int = 0
    @Published var healthPercent: Int = 0
    @Published var chargerWatts: Int = 0

    // Detailed info (for Info panel)
    @Published var temperature: Double = 0       // °C
    @Published var currentCapacityMAh: Int = 0   // mAh
    @Published var fullChargeCapacityMAh: Int = 0 // mAh
    @Published var designCapacityMAh: Int = 0    // mAh
    @Published var serial: String = ""
    @Published var adapterName: String = ""
    @Published var chargingWatts: Double = 0     // actual charging power
    @Published var voltage: Double = 0           // V

    private var fastTimer: Timer?  // 2s — battery %, charging state, charger watts
    private var slowTimer: Timer?  // 60s — cycle count, health (rarely changes)

    init() {
        updateFast()
        updateSlow()
    }

    func startMonitoring() {
        updateFast()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFast()
            }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSlow()
            }
        }
    }

    func stopMonitoring() {
        fastTimer?.invalidate()
        fastTimer = nil
        slowTimer?.invalidate()
        slowTimer = nil
    }

    /// Called externally for immediate refresh (e.g. on cycle engine tick)
    func update() {
        updateFast()
    }

    // MARK: - Fast updates (2s) — battery %, power source, charger

    private func updateFast() {
        // Read battery percentage and charging state from IOPowerSources
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
           let source = sources.first,
           let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {

            if let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
                percentage = capacity
            }
            if let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
                isPluggedIn = (powerSource == kIOPSACPowerValue)
            }
            if let charging = desc[kIOPSIsChargingKey] as? Bool {
                isCharging = charging
            }
        }

        // Read charger wattage from AppleSmartBattery
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else {
            chargerWatts = 0
            return
        }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            chargerWatts = 0
            return
        }

        // Only show charger watts when actually plugged in
        if isPluggedIn,
           let adapter = dict["AdapterDetails"] as? [String: Any],
           let watts = adapter["Watts"] as? Int {
            chargerWatts = watts
            adapterName = (adapter["Name"] as? String) ?? "\(watts)W Adapter"
        } else {
            chargerWatts = 0
            adapterName = ""
        }

        // Temperature (centidegrees → °C)
        if let temp = dict["Temperature"] as? Int {
            temperature = Double(temp) / 100.0
        }

        // Voltage (mV → V)
        if let v = dict["Voltage"] as? Int {
            voltage = Double(v) / 1000.0
        }

        // Actual charging/discharging power
        if let amp = dict["Amperage"] as? Int, let v = dict["Voltage"] as? Int {
            let ampVal = Int64(bitPattern: UInt64(bitPattern: Int64(amp)))
            chargingWatts = abs(Double(ampVal) * Double(v)) / 1_000_000
        } else {
            chargingWatts = 0
        }

        // Current capacity in mAh
        if let raw = dict["AppleRawCurrentCapacity"] as? Int {
            currentCapacityMAh = raw
        }
    }

    // MARK: - Slow updates (60s) — cycle count, health

    private func updateSlow() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }

        if let cycles = dict["CycleCount"] as? Int {
            cycleCount = cycles
        }
        if let s = dict["Serial"] as? String {
            serial = s
        }
        if let dc = dict["DesignCapacity"] as? Int {
            designCapacityMAh = dc
        }
        if let fc = dict["AppleRawMaxCapacity"] as? Int {
            fullChargeCapacityMAh = fc
        }

        // Read health from system_profiler (matches "About This Mac") — refreshed every 60s
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
