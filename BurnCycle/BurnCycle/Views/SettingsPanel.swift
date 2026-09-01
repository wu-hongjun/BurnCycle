import SwiftUI

/// Settings panel extracted from MainView: battery thresholds, outlet-control
/// shortcuts, behavior toggles, and the collapsible Load Generation / Advanced
/// section. Owns the threshold draft state so typing an intermediate value
/// doesn't drive the engine until "Save".
struct SettingsPanel: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var charging: ChargingController
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var stress: StressManager

    @State private var showAdvanced = false

    // Draft threshold values for the Settings input boxes. They hold the user's
    // edits until "Save" commits them to AppSettings, so typing an intermediate
    // value (e.g. "8" on the way to "80") doesn't momentarily drive the engine.
    @State private var upperDraft = 90
    @State private var lowerDraft = 5
    @State private var thresholdError: String?

    /// True when the draft boxes differ from the saved thresholds (enables Save).
    private var thresholdsDirty: Bool {
        upperDraft != Int(settings.upperThreshold) || lowerDraft != Int(settings.lowerThreshold)
    }

    /// Reload the draft boxes from the saved settings (called when the panel opens
    /// so discarded edits don't linger, and after a successful Save).
    private func syncThresholdDrafts() {
        upperDraft = Int(settings.upperThreshold)
        lowerDraft = Int(settings.lowerThreshold)
        thresholdError = nil
    }

    /// Validate and commit the draft thresholds. Ranges mirror the old sliders
    /// (charge 50–100, drain 5–50) and the engine's required 5% gap.
    private func saveThresholds() {
        let upper = min(max(upperDraft, 50), 100)
        let lower = min(max(lowerDraft, 5), 50)
        guard Double(upper) >= Double(lower) + AppSettings.minThresholdGap else {
            thresholdError = "Charge must be at least \(Int(AppSettings.minThresholdGap))% above drain."
            return
        }
        settings.upperThreshold = Double(upper)
        settings.lowerThreshold = Double(lower)
        upperDraft = upper
        lowerDraft = lower
        thresholdError = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // -- Battery Thresholds --
            HStack(spacing: 4) {
                Text("Battery Thresholds").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                InfoButton(text: "BurnCycle charges up to ‘Charge to’, then drains down to ‘Drain to’, repeating. ‘Charge to’ must be at least 5% above ‘Drain to’. Press Save to apply.")
                Spacer()
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Charge to")
                    TextField("", value: $upperDraft, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Text("%")
                }
                HStack(spacing: 4) {
                    Text("Drain to")
                    TextField("", value: $lowerDraft, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Text("%")
                }
                Spacer()
                Button("Save") { saveThresholds() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!thresholdsDirty)
            }
            if let thresholdError {
                Text(thresholdError)
                    .font(.caption2).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // -- Outlet Control --
            HStack(spacing: 4) {
                Text("Outlet Control").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                InfoButton(text: "Names of the Apple Shortcuts that switch your smart outlet. ‘Start’ must turn power ON, ‘Stop’ must turn it OFF. Tap Test to confirm each one actually toggles the outlet.")
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Start").font(.caption)
                            Button("Test") {
                                charging.testStartCharging(shortcutName: settings.startChargingShortcut)
                            }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(charging.isRunningShortcut)
                        }
                        TextField("Start shortcut", text: $settings.startChargingShortcut)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Stop").font(.caption)
                            Button("Test") {
                                charging.testStopCharging(shortcutName: settings.stopChargingShortcut)
                            }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(charging.isRunningShortcut)
                        }
                        TextField("Stop shortcut", text: $settings.stopChargingShortcut)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if engine.isRunning {
                    Text("Shortcut name changes apply on the next charge/drain phase.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Text("Behavior").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
            HStack(spacing: 4) {
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                InfoButton(text: "Adds a menu-bar item showing cycle state with a Start/Stop popover — useful when the main window is closed.")
                Spacer()
            }
            if settings.showInMenuBar {
                HStack(spacing: 4) {
                    Toggle("Show battery percentage", isOn: $settings.showBatteryPercentageInMenuBar)
                    InfoButton(text: "Shows the current battery percentage beside the BurnCycle menu-bar icon. Off by default for a compact icon.")
                    Spacer()
                }
                .padding(.leading, 18)
                HStack(spacing: 4) {
                    Toggle("Hide Dock icon", isOn: $settings.hideDockIcon)
                    InfoButton(text: "Removes BurnCycle from the Dock while keeping it active in the menu bar. Reopen the window from the menu-bar popover. Quit still closes the entire app.")
                    Spacer()
                }
                .padding(.leading, 18)
            }
            HStack(spacing: 4) {
                Toggle("Pause cycling when Mac sleeps", isOn: $settings.pauseOnSleep)
                InfoButton(text: "Stops the cycle when the Mac sleeps and resumes it on wake, so the battery isn’t drained unattended while asleep.")
                Spacer()
            }
            HStack(spacing: 4) {
                Toggle("Relaunch if killed mid-cycle", isOn: $settings.watchdogEnabled)
                InfoButton(text: "Restores charging and resumes if the app is closed unexpectedly while draining. Recommended.")
                Spacer()
            }

            Text("Load Generation").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
            HStack(spacing: 4) {
                Toggle("Generate load while draining", isOn: $settings.loadEnabled)
                InfoButton(text: "Actively burns CPU/GPU while draining so the battery discharges faster. Off = drain only from normal use. Pick how under Advanced ▸ Load Method.")
                Spacer()
            }

            // -- Advanced (collapsed): load method --
            // Hand-rolled disclosure: a plain Button toggling `showAdvanced`
            // is reliable both ways, unlike DisclosureGroup(isExpanded:) which
            // can stick open when it hosts controls (Picker/TextField/Toggle).
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Advanced").font(.caption).fontWeight(.semibold)
                    Spacer()
                }
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    if settings.loadEnabled {
                        HStack(spacing: 4) {
                            Text("Load Method").font(.caption).foregroundColor(.secondary)
                            InfoButton(text: "Stress Test: offline CPU+GPU load, nothing leaves your Mac. Mine XMR: runs the bundled miner (needs internet); an empty wallet mines to the developer’s donation address.")
                            Spacer()
                        }
                        Picker("Load Method", selection: $settings.loadMethod) {
                            ForEach(LoadMethod.allCases, id: \.rawValue) { method in
                                Text(method.rawValue).tag(method.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if settings.selectedLoadMethod == .mine {
                            VStack(alignment: .leading) {
                                HStack(spacing: 4) {
                                    Text("XMR Wallet (empty = default)")
                                        .font(.caption).foregroundColor(.secondary)
                                    InfoButton(text: "Your Monero payout address. Leave empty to mine to the developer’s donation wallet (the status line shows when the donation wallet is active).")
                                    Spacer()
                                }
                                TextField("Wallet address", text: $settings.walletAddress)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))
                            }

                            if mining.isMining {
                                HStack {
                                    Text("Mining: \(mining.status)")
                                    Spacer()
                                    Text(mining.hashrate).fontWeight(.medium).foregroundColor(.green)
                                }
                                .font(.caption)
                            }
                        } else {
                            Text("Stress test uses all CPU cores + GPU via Metal. No internet required.")
                                .font(.caption).foregroundColor(.secondary)

                            if stress.isRunning {
                                HStack {
                                    Text("Status:")
                                    Text(stress.status).fontWeight(.medium).foregroundColor(.orange)
                                }
                                .font(.caption)
                            }

                            if let stressErr = stress.lastError {
                                Label(stressErr, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundColor(.orange)
                            }
                        }

                        if engine.loadThrottled {
                            Label("Load paused — system busy (CPU/GPU > 80%)",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundColor(.orange)
                        }
                    } else {
                        Text("Turn on “Generate load while draining” to pick a load method.")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    Divider()

                    HStack(spacing: 4) {
                        Button("Force re-test before next Start") {
                            engine.invalidatePreflightCache()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(engine.isRunning || !engine.hasCachedPreflight)
                        InfoButton(text: "Before the first Start, BurnCycle flips your outlet off then on to confirm the Shortcut really controls power. That check is reused for 30 minutes. Use this to force a fresh check after moving the plug or changing hubs.")
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Quit BurnCycle") {
                    engine.stop()
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption).foregroundColor(.red)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.top, 4)
        .onAppear { syncThresholdDrafts() }
    }
}
