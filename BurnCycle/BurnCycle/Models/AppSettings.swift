import Foundation
import SwiftUI

enum LoadMethod: String, CaseIterable {
    case mine = "Mine XMR"
    case stress = "Stress Test"
}

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
