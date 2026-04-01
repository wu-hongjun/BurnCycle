# Battery Burner Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS menubar app that cycles MacBook battery between configurable thresholds using HomeKit outlet control (via Shortcuts) and Monero mining (via xmrig) for discharge.

**Architecture:** SwiftUI MenuBarExtra app with four service classes (BatteryMonitor, ChargingController, MiningManager, CycleEngine) coordinated by a state machine. All settings persisted via UserDefaults.

**Tech Stack:** Swift 6.3, SwiftUI, IOKit (battery), Foundation Process (subprocesses), UserDefaults (persistence)

---

### Task 1: Create Xcode Project Structure

**Files:**
- Create: Xcode project via command line
- Create: `BatteryBurner/BatteryBurnerApp.swift`
- Create: `BatteryBurner/Info.plist`

**Step 1: Create the Xcode project**

```bash
cd /Users/hongjunwu/Documents/Git/battery-burner
mkdir -p BatteryBurner/BatteryBurner
```

Create `BatteryBurner/BatteryBurner/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

**Step 2: Create a minimal app entry point**

Create `BatteryBurner/BatteryBurner/BatteryBurnerApp.swift`:
```swift
import SwiftUI

@main
struct BatteryBurnerApp: App {
    var body: some Scene {
        MenuBarExtra("Battery Burner", systemImage: "battery.100.bolt") {
            Text("Battery Burner")
                .padding()
        }
    }
}
```

**Step 3: Create Package.swift for building**

We'll use a Swift Package with a macOS app target to avoid manual xcodeproj authoring.

Create `BatteryBurner/Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryBurner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BatteryBurner",
            path: "BatteryBurner",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
```

**Step 4: Build and verify it compiles**

```bash
cd /Users/hongjunwu/Documents/Git/battery-burner/BatteryBurner
swift build
```
Expected: Build succeeds

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: scaffold macOS menubar app with SwiftPM"
```

---

### Task 2: BatteryMonitor Service

**Files:**
- Create: `BatteryBurner/BatteryBurner/Services/BatteryMonitor.swift`

**Step 1: Implement BatteryMonitor**

```swift
import Foundation
import IOKit.ps
import Combine

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published var percentage: Int = 0
    @Published var isPluggedIn: Bool = false
    @Published var isCharging: Bool = false

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
    }
}
```

**Step 2: Build and verify**

```bash
cd /Users/hongjunwu/Documents/Git/battery-burner/BatteryBurner
swift build
```
Expected: PASS

**Step 3: Commit**

```bash
git add BatteryBurner/Services/BatteryMonitor.swift
git commit -m "feat: add BatteryMonitor service using IOKit"
```

---

### Task 3: ChargingController Service

**Files:**
- Create: `BatteryBurner/BatteryBurner/Services/ChargingController.swift`

**Step 1: Implement ChargingController**

```swift
import Foundation

@MainActor
final class ChargingController: ObservableObject {
    @Published var lastAction: String = "None"
    @Published var isRunningShortcut: Bool = false

    private var lastActionTime: Date = .distantPast
    private let cooldown: TimeInterval = 30

    func startCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "Start Charging")
    }

    func stopCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "Stop Charging")
    }

    private func runShortcut(name: String, action: String) {
        let now = Date()
        guard now.timeIntervalSince(lastActionTime) >= cooldown else { return }
        guard !isRunningShortcut else { return }

        lastActionTime = now
        isRunningShortcut = true

        let shortcutName = name
        Task.detached { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", shortcutName]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Shortcut execution failed — log silently
            }

            await MainActor.run {
                self?.lastAction = action
                self?.isRunningShortcut = false
            }
        }
    }
}
```

**Step 2: Build and verify**

```bash
swift build
```
Expected: PASS

**Step 3: Commit**

```bash
git add BatteryBurner/Services/ChargingController.swift
git commit -m "feat: add ChargingController service via Apple Shortcuts"
```

---

### Task 4: MiningManager Service

**Files:**
- Create: `BatteryBurner/BatteryBurner/Services/MiningManager.swift`

**Step 1: Implement MiningManager**

```swift
import Foundation

@MainActor
final class MiningManager: ObservableObject {
    @Published var isMining: Bool = false
    @Published var hashrate: String = "0 H/s"

    private var process: Process?
    private var outputPipe: Pipe?

    func start(xmrigPath: String, poolURL: String, wallet: String, threads: Int) {
        guard !isMining else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: xmrigPath)
        proc.arguments = [
            "--url", poolURL,
            "--user", wallet,
            "--threads", "\(threads)",
            "--no-color",
            "--print-time", "30"
        ]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.parseHashrate(from: line)
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isMining = false
                self?.hashrate = "0 H/s"
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = pipe
            isMining = true
        } catch {
            isMining = false
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            isMining = false
            return
        }
        proc.terminate()
        process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        isMining = false
        hashrate = "0 H/s"
    }

    private func parseHashrate(from output: String) {
        // xmrig outputs lines like: "[2024-01-01 12:00:00.000] speed 10s/60s/15m 1234.5 1200.0 1190.0 H/s max 1300.0 H/s"
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.contains("speed") && line.contains("H/s") {
                if let range = line.range(of: #"\d+\.?\d*\s*[kMG]?H/s"#, options: .regularExpression) {
                    let parsed = String(line[range])
                    Task { @MainActor in
                        self.hashrate = parsed
                    }
                }
            }
        }
    }

    deinit {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }
}
```

**Step 2: Build and verify**

```bash
swift build
```
Expected: PASS

**Step 3: Commit**

```bash
git add BatteryBurner/Services/MiningManager.swift
git commit -m "feat: add MiningManager service for xmrig process control"
```

---

### Task 5: Settings / AppState Model

**Files:**
- Create: `BatteryBurner/BatteryBurner/Models/AppSettings.swift`

**Step 1: Implement AppSettings with UserDefaults persistence**

```swift
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
```

**Step 2: Build and verify**

```bash
swift build
```
Expected: PASS

**Step 3: Commit**

```bash
git add BatteryBurner/Models/AppSettings.swift
git commit -m "feat: add AppSettings model with UserDefaults persistence"
```

---

### Task 6: CycleEngine State Machine

**Files:**
- Create: `BatteryBurner/BatteryBurner/Services/CycleEngine.swift`

**Step 1: Implement CycleEngine**

```swift
import Foundation
import Combine

enum CycleState: String {
    case charging = "CHARGING"
    case draining = "DRAINING"
    case paused = "PAUSED"
    case idle = "IDLE"
}

@MainActor
final class CycleEngine: ObservableObject {
    @Published var state: CycleState = .idle
    @Published var cycleCount: Int = 0
    @Published var isRunning: Bool = false

    private let battery: BatteryMonitor
    private let charging: ChargingController
    private let mining: MiningManager
    private let settings: AppSettings

    private var timer: Timer?
    private var wasBelowLower = false

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager, settings: AppSettings) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        battery.startMonitoring()

        // Determine initial state
        if battery.percentage >= Int(settings.upperThreshold) {
            transitionToDraining()
        } else {
            transitionToCharging()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        mining.stop()
        battery.stopMonitoring()
        state = .idle
    }

    func pause() {
        guard isRunning else { return }
        mining.stop()
        charging.startCharging(shortcutName: settings.startChargingShortcut)
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        tick()
    }

    private func tick() {
        guard isRunning, state != .paused else { return }
        battery.update()

        let pct = battery.percentage
        let upper = Int(settings.upperThreshold)
        let lower = Int(settings.lowerThreshold)

        switch state {
        case .charging:
            if pct >= upper {
                transitionToDraining()
            }
        case .draining:
            if pct <= lower {
                cycleCount += 1
                transitionToCharging()
            }
        default:
            break
        }
    }

    private func transitionToCharging() {
        mining.stop()
        charging.startCharging(shortcutName: settings.startChargingShortcut)
        state = .charging
    }

    private func transitionToDraining() {
        charging.stopCharging(shortcutName: settings.stopChargingShortcut)

        guard !settings.walletAddress.isEmpty else {
            state = .draining
            return
        }

        mining.start(
            xmrigPath: settings.xmrigPath,
            poolURL: settings.poolURL,
            wallet: settings.walletAddress,
            threads: settings.threadCount
        )
        state = .draining
    }
}
```

**Step 2: Build and verify**

```bash
swift build
```
Expected: PASS

**Step 3: Commit**

```bash
git add BatteryBurner/Services/CycleEngine.swift
git commit -m "feat: add CycleEngine state machine orchestrator"
```

---

### Task 7: SwiftUI Popover Views

**Files:**
- Create: `BatteryBurner/BatteryBurner/Views/StatusSection.swift`
- Create: `BatteryBurner/BatteryBurner/Views/ControlsSection.swift`
- Create: `BatteryBurner/BatteryBurner/Views/SettingsSection.swift`
- Create: `BatteryBurner/BatteryBurner/Views/PopoverView.swift`

**Step 1: Create StatusSection**

```swift
import SwiftUI

struct StatusSection: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Battery")
                    .font(.headline)
                Spacer()
                Text("\(battery.percentage)%")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            ProgressView(value: Double(battery.percentage), total: 100)
                .tint(batteryColor)

            HStack {
                Text("State:")
                Text(engine.state.rawValue)
                    .fontWeight(.semibold)
                    .foregroundColor(stateColor)
            }

            if mining.isMining {
                HStack {
                    Text("Hashrate:")
                    Text(mining.hashrate)
                        .fontWeight(.medium)
                }
            }

            if engine.cycleCount > 0 {
                HStack {
                    Text("Cycles:")
                    Text("\(engine.cycleCount)")
                }
            }
        }
    }

    private var batteryColor: Color {
        if battery.percentage > 60 { return .green }
        if battery.percentage > 20 { return .yellow }
        return .red
    }

    private var stateColor: Color {
        switch engine.state {
        case .charging: return .green
        case .draining: return .orange
        case .paused: return .yellow
        case .idle: return .secondary
        }
    }
}
```

**Step 2: Create ControlsSection**

```swift
import SwiftUI

struct ControlsSection: View {
    @ObservedObject var engine: CycleEngine

    var body: some View {
        HStack(spacing: 12) {
            Button(engine.isRunning ? "Stop" : "Start") {
                if engine.isRunning {
                    engine.stop()
                } else {
                    engine.start()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .green)

            if engine.isRunning {
                Button(engine.state == .paused ? "Resume" : "Pause") {
                    if engine.state == .paused {
                        engine.resume()
                    } else {
                        engine.pause()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
```

**Step 3: Create SettingsSection**

```swift
import SwiftUI

struct SettingsSection: View {
    @ObservedObject var settings: AppSettings
    let maxThreads: Int

    var body: some View {
        DisclosureGroup("Settings") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading) {
                    Text("Upper Threshold: \(Int(settings.upperThreshold))%")
                    Slider(value: $settings.upperThreshold, in: 50...100, step: 5)
                }

                VStack(alignment: .leading) {
                    Text("Lower Threshold: \(Int(settings.lowerThreshold))%")
                    Slider(value: $settings.lowerThreshold, in: 5...50, step: 5)
                }

                Divider()

                VStack(alignment: .leading) {
                    Text("Wallet Address")
                    TextField("XMR wallet address", text: $settings.walletAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }

                VStack(alignment: .leading) {
                    Text("Pool URL")
                    TextField("pool:port", text: $settings.poolURL)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading) {
                    Text("Threads: \(settings.threadCount)")
                    Slider(value: Binding(
                        get: { Double(settings.threadCount) },
                        set: { settings.threadCount = Int($0) }
                    ), in: 1...Double(maxThreads), step: 1)
                }

                Divider()

                VStack(alignment: .leading) {
                    Text("Start Charging Shortcut")
                    TextField("Shortcut name", text: $settings.startChargingShortcut)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading) {
                    Text("Stop Charging Shortcut")
                    TextField("Shortcut name", text: $settings.stopChargingShortcut)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading) {
                    Text("XMRig Path")
                    TextField("/opt/homebrew/bin/xmrig", text: $settings.xmrigPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }
}
```

**Step 4: Create PopoverView**

```swift
import SwiftUI

struct PopoverView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var settings: AppSettings
    let maxThreads: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusSection(battery: battery, engine: engine, mining: mining)

            Divider()

            ControlsSection(engine: engine)

            Divider()

            SettingsSection(settings: settings, maxThreads: maxThreads)

            Divider()

            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .foregroundColor(.secondary)
            .font(.caption)
        }
        .padding()
        .frame(width: 320)
    }
}
```

**Step 5: Build and verify**

```bash
swift build
```
Expected: PASS

**Step 6: Commit**

```bash
git add BatteryBurner/Views/
git commit -m "feat: add SwiftUI popover views (status, controls, settings)"
```

---

### Task 8: Wire Up App Entry Point

**Files:**
- Modify: `BatteryBurner/BatteryBurner/BatteryBurnerApp.swift`

**Step 1: Update app entry point to wire all components**

```swift
import SwiftUI

@main
struct BatteryBurnerApp: App {
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var charging = ChargingController()
    @StateObject private var mining = MiningManager()
    @StateObject private var settings = AppSettings()
    @State private var engine: CycleEngine?

    private let maxThreads = ProcessInfo.processInfo.processorCount

    var body: some Scene {
        MenuBarExtra("Battery Burner", systemImage: menuBarIcon) {
            if let engine = engine {
                PopoverView(
                    battery: battery,
                    engine: engine,
                    mining: mining,
                    settings: settings,
                    maxThreads: maxThreads
                )
            } else {
                ProgressView()
                    .onAppear {
                        let eng = CycleEngine(
                            battery: battery,
                            charging: charging,
                            mining: mining,
                            settings: settings
                        )
                        engine = eng
                    }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        guard let engine = engine else { return "battery.100" }
        switch engine.state {
        case .charging: return "battery.100.bolt"
        case .draining: return "battery.50"
        case .paused: return "battery.75"
        case .idle: return "battery.100"
        }
    }
}
```

**Step 2: Build and verify**

```bash
swift build
```
Expected: PASS

**Step 3: Commit**

```bash
git add BatteryBurner/BatteryBurnerApp.swift
git commit -m "feat: wire up app entry point with all services"
```

---

### Task 9: Final Build and Run Test

**Step 1: Clean build**

```bash
cd /Users/hongjunwu/Documents/Git/battery-burner/BatteryBurner
swift build -c release
```
Expected: Build succeeds

**Step 2: Run the app**

```bash
.build/release/BatteryBurner &
```
Expected: Menubar icon appears, popover opens on click

**Step 3: Commit any fixes and tag**

```bash
git add -A
git commit -m "feat: Battery Burner v1.0 - complete macOS menubar app"
```
