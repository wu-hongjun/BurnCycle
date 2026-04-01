import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("upperThreshold") var upperThreshold: Double = 95
    @AppStorage("lowerThreshold") var lowerThreshold: Double = 10
    @AppStorage("walletAddress") var walletAddress: String = ""
    @AppStorage("poolURL") var poolURL: String = "xmr-us-east1.nanopool.org:14433"
    @AppStorage("threadCount") var threadCount: Int = 8
    @AppStorage("startChargingShortcut") var startChargingShortcut: String = "Start Charging"
    @AppStorage("stopChargingShortcut") var stopChargingShortcut: String = "Stop Charging"
    @AppStorage("useNativeMiner") var useNativeMiner: Bool = true
    @AppStorage("useGPU") var useGPU: Bool = true
    @AppStorage("useNativeGPU") var useNativeGPU: Bool = true
    @AppStorage("useANE") var useANE: Bool = true
    @AppStorage("xmrigPath") var xmrigPath: String = "/opt/homebrew/bin/xmrig"
}
