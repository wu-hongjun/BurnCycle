import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("upperThreshold") var upperThreshold: Double = 95
    @AppStorage("lowerThreshold") var lowerThreshold: Double = 10
    @AppStorage("loadEnabled") var loadEnabled: Bool = true
    @AppStorage("startChargingShortcut") var startChargingShortcut: String = "Start Charging"
    @AppStorage("stopChargingShortcut") var stopChargingShortcut: String = "Stop Charging"
}
