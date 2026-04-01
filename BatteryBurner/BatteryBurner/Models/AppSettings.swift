import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("upperThreshold") var upperThreshold: Double = 95
    @AppStorage("lowerThreshold") var lowerThreshold: Double = 10
    @AppStorage("walletAddress") var walletAddress: String = ""
    @AppStorage("poolURL") var poolURL: String = "pool.supportxmr.com:443"
    @AppStorage("threadCount") var threadCount: Int = 8
    @AppStorage("startChargingShortcut") var startChargingShortcut: String = "Start Charging"
    @AppStorage("stopChargingShortcut") var stopChargingShortcut: String = "Stop Charging"
    @AppStorage("xmrigPath") var xmrigPath: String = "/opt/homebrew/bin/xmrig"
}
