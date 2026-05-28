import Foundation
import SwiftUI

/// How BurnCycle generates load while draining the battery.
enum LoadMethod: String, CaseIterable {
    case mine = "Mine XMR"
    case stress = "Stress Test"
}

/// User-facing preferences. All values are backed by `@AppStorage` so they
/// persist across launches and stay in sync with any view bound to the same key.
@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("upperThreshold") var upperThreshold: Double = 90
    @AppStorage("lowerThreshold") var lowerThreshold: Double = 5
    @AppStorage("loadEnabled") var loadEnabled: Bool = true
    @AppStorage("loadMethod") var loadMethod: String = LoadMethod.stress.rawValue
    @AppStorage("walletAddress") var walletAddress: String = ""
    @AppStorage("startChargingShortcut") var startChargingShortcut: String = "Start Charging"
    @AppStorage("stopChargingShortcut") var stopChargingShortcut: String = "Stop Charging"
    @AppStorage("pauseOnSleep") var pauseOnSleep: Bool = true
    @AppStorage("showInMenuBar") var showInMenuBar: Bool = false

    /// Dim the display while the cycle is charging, then restore the prior
    /// brightness when it switches to draining. Opt-in (off by default) and
    /// only honored when `BrightnessController.isAvailable`.
    @AppStorage("dimWhileCharging") var dimWhileCharging: Bool = false
    /// Brightness applied while dimming (0.0–1.0). Default 10%.
    @AppStorage("dimBrightness") var dimBrightness: Double = 0.10

    /// Typed accessor over the raw `loadMethod` string. Falls back to `.stress`
    /// if the stored value can't be parsed (e.g. a stale key from a prior build).
    var selectedLoadMethod: LoadMethod {
        get { LoadMethod(rawValue: loadMethod) ?? .stress }
        set { loadMethod = newValue.rawValue }
    }

    // Validated thresholds — the raw @AppStorage values back the sliders, but the
    // engine must never act on upper <= lower (it would thrash, charging and draining
    // at the same percentage). These accessors guarantee a minimum 5% gap so the
    // engine always sees a sane band regardless of how the sliders were dragged.
    static let minThresholdGap: Double = 5

    /// Effective lower threshold the engine should use for comparisons.
    var effectiveLowerThreshold: Double {
        // Lower can never exceed (upper - gap). Clamp it down if it would.
        min(lowerThreshold, upperThreshold - Self.minThresholdGap)
    }

    /// Effective upper threshold the engine should use for comparisons.
    var effectiveUpperThreshold: Double {
        // Upper must always be at least gap above the (raw) lower threshold.
        max(upperThreshold, lowerThreshold + Self.minThresholdGap)
    }
}
