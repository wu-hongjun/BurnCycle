import Foundation
import IOKit
import IOKit.ps

/// Battery telemetry, polled on three cadences:
///  - fast (2s): percentage, plugged-in state, charger watts, voltage, temperature.
///  - slow (60s): cycle count, serial, design / full capacity (cheap IORegistry).
///  - hourly: `Maximum Capacity` via `system_profiler` (expensive subprocess).
/// All `@Published` values stay on whatever they were last read as if a poll fails,
/// so a transient IORegistry miss never zeroes the UI or trips the cycle engine.
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

    /// True when the machine actually has an internal battery power source.
    /// CycleEngine reads this to refuse cycling on a desktop Mac (no battery).
    @Published var hasBattery: Bool = true
    /// True when the `system_profiler` health read failed to launch or parse.
    /// UI may surface this as "Health unavailable" so a failed read is not
    /// indistinguishable from a genuine 0% reading.
    @Published var healthReadFailed: Bool = false

    private var fastTimer: Timer?  // 2s — battery %, charging state, charger watts
    private var slowTimer: Timer?  // 60s — cycle count, IORegistry-only (cheap reads)
    private var healthTimer: Timer? // 1h — system_profiler health read (expensive subprocess)

    // Throttle for `system_profiler` reads. Battery health changes at most once per
    // week, so spawning a subprocess every 60s is wasteful.
    private var lastHealthRead: Date = .distantPast
    private let healthMinInterval: TimeInterval = 60 * 60   // 1 hour

    init() {
        updateFast()
        updateSlow()
        // Populate `healthPercent` on cold launch. Setting `lastHealthRead` here
        // ensures that an on-demand `refreshHealth()` call within the next hour
        // is correctly suppressed.
        refreshHealthDetail()
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
        // Hourly system_profiler refresh. Fires `refreshHealthDetail` directly,
        // bypassing the throttle — the timer interval IS the throttle.
        healthTimer = Timer.scheduledTimer(withTimeInterval: healthMinInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshHealthDetail()
            }
        }
    }

    func stopMonitoring() {
        fastTimer?.invalidate()
        fastTimer = nil
        slowTimer?.invalidate()
        slowTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// Called externally for immediate refresh (e.g. on cycle engine tick)
    func update() {
        updateFast()
    }

    /// Trigger a fresh health read. No-op if a read happened recently
    /// (within `healthMinInterval`) — caller doesn't need to throttle.
    func refreshHealth() {
        if Date().timeIntervalSince(lastHealthRead) < healthMinInterval { return }
        refreshHealthDetail()
    }

    // MARK: - Fast updates (2s) — battery %, power source, charger

    private func updateFast() {
        // Read battery percentage and charging state from IOPowerSources.
        // Also detect whether an internal battery power source actually exists
        // (false on a desktop Mac), which CycleEngine uses to refuse cycling.
        // L1: on a failed read we intentionally keep the previous values rather
        // than zeroing them — a transient IOPowerSources miss shouldn't flip the
        // engine's transition decisions. `hasBattery` is only flipped false when
        // we positively confirm no internal battery is present.
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {

            let internalSource = sources.first { source in
                guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any] else { return false }
                return (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            }

            if let source = internalSource,
               let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                hasBattery = true
                if let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
                    percentage = capacity
                }
                if let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
                    isPluggedIn = (powerSource == kIOPSACPowerValue)
                }
                if let charging = desc[kIOPSIsChargingKey] as? Bool {
                    isCharging = charging
                }
            } else if !sources.isEmpty {
                // Power sources exist but none is an internal battery → desktop Mac.
                hasBattery = false
            }
        }

        // Read charger / power details from AppleSmartBattery.
        // F-01: read only the specific keys needed in the fast path via
        // IORegistryEntryCreateCFProperty, avoiding the full-dictionary
        // allocation that IORegistryEntryCreateCFProperties performed every 2s.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else {
            chargerWatts = 0
            // No AppleSmartBattery service is a strong battery-less (desktop) signal.
            // This covers the cold-launch case where IOPowerSources returned an empty
            // list and we couldn't otherwise confirm. Self-corrects on the next tick.
            hasBattery = false
            return
        }
        defer { IOObjectRelease(service) }

        // AppleSmartBattery matched → there is a battery, even if IOPowerSources
        // didn't report one this tick.
        hasBattery = true

        // AdapterDetails — only show charger watts when actually plugged in.
        // Single-key reads via IORegistry.property (F-01/F-02): avoids full-dictionary
        // allocation every 2s.
        if isPluggedIn,
           let adapter = IORegistry.property(service, "AdapterDetails") as? [String: Any],
           let watts = adapter["Watts"] as? Int {
            chargerWatts = watts
            adapterName = (adapter["Name"] as? String) ?? "\(watts)W Adapter"
        } else {
            chargerWatts = 0
            adapterName = ""
        }

        // Temperature (centidegrees → °C)
        if let temp = IORegistry.property(service, "Temperature") as? Int {
            temperature = Double(temp) / 100.0
        }

        // Voltage (mV → V)
        let voltageRaw = IORegistry.property(service, "Voltage") as? Int
        if let v = voltageRaw {
            voltage = Double(v) / 1000.0
        }

        // Actual charging/discharging power
        if let amp = IORegistry.property(service, "Amperage") as? Int, let v = voltageRaw {
            let ampVal = Int64(bitPattern: UInt64(bitPattern: Int64(amp)))
            chargingWatts = abs(Double(ampVal) * Double(v)) / 1_000_000
        } else {
            chargingWatts = 0
        }

        // Current capacity in mAh
        if let raw = IORegistry.property(service, "AppleRawCurrentCapacity") as? Int {
            currentCapacityMAh = raw
        }
    }

    // MARK: - Slow updates (60s) — cycle count, capacity (IORegistry only, cheap)

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
    }

    // MARK: - Hourly / on-demand health (system_profiler subprocess)

    /// Spawns `/usr/sbin/system_profiler` to read "Maximum Capacity" — matches
    /// the value shown in About This Mac. Heavy (~1-2s, ~50MB RAM), so this is
    /// gated to once per `healthMinInterval` via `refreshHealth()`.
    /// The timer fires this directly (the timer interval is the throttle).
    private func refreshHealthDetail() {
        // Keep the throttle stamp at the start so concurrent/rapid callers are
        // suppressed (preserves existing throttle semantics, n1). A failed parse
        // surfaces via `healthReadFailed` rather than silently showing 0%.
        lastHealthRead = Date()
        Task.detached { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            proc.arguments = ["SPPowerDataType"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            // Always close the read handle, on every exit path (M2).
            defer { try? pipe.fileHandleForReading.close() }

            // H1/L5: surface a launch failure instead of swallowing it with `try?`.
            // Without a successful run() the pipe write-end is never connected and
            // readDataToEndOfFile() would block the detached thread forever (M2).
            do {
                try proc.run()
            } catch {
                await MainActor.run { self?.healthReadFailed = true }
                return
            }
            proc.waitUntilExit()

            // L-4: system_profiler output is bounded (~3-10 KB), but cap the read
            // defensively so an anomalous run can't allocate unbounded memory.
            let maxBytes = 256 * 1024
            let data = pipe.fileHandleForReading.readData(ofLength: maxBytes)

            if let output = String(data: data, encoding: .utf8),
               let range = output.range(of: #"Maximum Capacity:\s+(\d+)%"#, options: .regularExpression) {
                let match = output[range]
                if let numRange = match.range(of: #"\d+"#, options: .regularExpression),
                   let value = Int(match[numRange]) {
                    await MainActor.run {
                        self?.healthPercent = value
                        self?.healthReadFailed = false
                    }
                    return
                }
            }
            // Ran but produced no parseable "Maximum Capacity" value.
            await MainActor.run { self?.healthReadFailed = true }
        }
    }
}
