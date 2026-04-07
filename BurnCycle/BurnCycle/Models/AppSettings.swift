import Foundation
import SwiftUI

enum LoadMethod: String, CaseIterable {
    case mine = "Mine XMR"
    case stress = "Stress Test"
}

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("upperThreshold") var upperThreshold: Double = 95
    @AppStorage("lowerThreshold") var lowerThreshold: Double = 10
    @AppStorage("loadEnabled") var loadEnabled: Bool = true
    @AppStorage("loadMethod") var loadMethod: String = LoadMethod.stress.rawValue
    @AppStorage("walletAddress") var walletAddress: String = ""
    @AppStorage("startChargingShortcut") var startChargingShortcut: String = "Start Charging"
    @AppStorage("stopChargingShortcut") var stopChargingShortcut: String = "Stop Charging"

    var selectedLoadMethod: LoadMethod {
        get { LoadMethod(rawValue: loadMethod) ?? .stress }
        set { loadMethod = newValue.rawValue }
    }
}
