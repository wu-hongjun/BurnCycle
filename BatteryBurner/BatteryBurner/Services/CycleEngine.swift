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
    private let nativeMiner: NativeMiner
    private let gpuStresser: GPUStresser
    private let aneStresser: ANEStresser
    private let settings: AppSettings

    private var timer: Timer?

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager,
         nativeMiner: NativeMiner, gpuStresser: GPUStresser, aneStresser: ANEStresser, settings: AppSettings) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.nativeMiner = nativeMiner
        self.gpuStresser = gpuStresser
        self.aneStresser = aneStresser
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        battery.startMonitoring()

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
        stopAllStress()
        battery.stopMonitoring()
        state = .idle
    }

    func pause() {
        guard isRunning else { return }
        stopAllStress()
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
        stopAllStress()
        charging.startCharging(shortcutName: settings.startChargingShortcut)
        state = .charging
    }

    private func transitionToDraining() {
        charging.stopCharging(shortcutName: settings.stopChargingShortcut)

        guard !settings.walletAddress.isEmpty else {
            state = .draining
            return
        }

        if settings.useNativeMiner {
            // Native miner: CPU (RandomX) + Metal GPU + ANE
            nativeMiner.start(
                poolURL: settings.poolURL,
                wallet: settings.walletAddress,
                threads: settings.threadCount,
                useGPU: settings.useNativeGPU,
                useANE: settings.useANE
            )
        } else {
            // xmrig fallback: CPU + OpenCL GPU
            mining.start(
                xmrigPath: settings.xmrigPath,
                poolURL: settings.poolURL,
                wallet: settings.walletAddress,
                threads: settings.threadCount,
                useGPU: settings.useGPU
            )
            // Start native GPU/ANE stress alongside xmrig
            if settings.useNativeGPU { gpuStresser.start() }
            if settings.useANE { aneStresser.start() }
        }

        state = .draining
    }

    private func stopAllStress() {
        mining.stop()
        nativeMiner.stop()
        gpuStresser.stop()
        aneStresser.stop()
    }
}
