import Foundation
import Metal
import Accelerate
import CRandomX

/// Native Monero miner using RandomX across CPU (GCD), GPU (Metal), and ANE (Accelerate/MPS).
/// Connects to pool via Stratum v1 and submits shares independently.
@MainActor
final class NativeMiner: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var hashrate: String = "0 H/s"
    @Published var status: String = "Idle"
    @Published var sharesFound: Int = 0

    private let gpuStresser: GPUStresser
    private let aneStresser: ANEStresser
    private let stratum = StratumClient()
    private var cpuWorkers: [Task<Void, Never>] = []
    private var hashrateTimer: Timer?
    private var hashCount: UInt64 = 0
    private var lastHashCount: UInt64 = 0
    private var lastHashTime: Date = Date()

    // RandomX state — shared across workers (read-only after init)
    private var rxCache: OpaquePointer?
    private var rxDataset: OpaquePointer?
    private var currentSeedHash: Data?

    init(gpuStresser: GPUStresser, aneStresser: ANEStresser) {
        self.gpuStresser = gpuStresser
        self.aneStresser = aneStresser
    }

    func start(poolURL: String, wallet: String, threads: Int, useGPU: Bool, useANE: Bool) {
        guard !isRunning else { return }
        isRunning = true
        status = "Connecting..."
        hashCount = 0
        lastHashCount = 0
        lastHashTime = Date()
        sharesFound = 0

        // Parse pool URL
        let parts = poolURL.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            status = "Invalid pool URL"
            isRunning = false
            return
        }

        // Set up job handler
        stratum.onNewJob = { [weak self] job in
            Task { @MainActor in
                self?.handleNewJob(job, threads: threads)
            }
        }
        stratum.connect(host: String(parts[0]), port: port, wallet: wallet, useTLS: true)

        // Start GPU stress (Metal compute for power draw)
        if useGPU {
            gpuStresser.start()
        }

        // Start ANE stress (AMX matrix ops for power draw)
        if useANE {
            aneStresser.start()
        }

        // Start hashrate timer
        hashrateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateHashrate()
            }
        }
    }

    func stop() {
        for worker in cpuWorkers { worker.cancel() }
        cpuWorkers.removeAll()
        gpuStresser.stop()
        aneStresser.stop()
        stratum.disconnect()
        hashrateTimer?.invalidate()
        hashrateTimer = nil
        cleanupRandomX()
        isRunning = false
        hashrate = "0 H/s"
        status = "Stopped"
    }

    // MARK: - RandomX Setup

    private func initRandomX(seedHash: Data) {
        // Only reinitialize if seed changed
        if seedHash == currentSeedHash { return }
        currentSeedHash = seedHash

        status = "Initializing RandomX..."

        cleanupRandomX()

        let flags = randomx_flags(RANDOMX_FLAG_DEFAULT.rawValue | RANDOMX_FLAG_HARD_AES.rawValue | RANDOMX_FLAG_JIT.rawValue | RANDOMX_FLAG_FULL_MEM.rawValue)

        // Allocate and init cache
        rxCache = randomx_alloc_cache(flags)
        guard let cache = rxCache else {
            status = "Failed to allocate RandomX cache"
            return
        }
        seedHash.withUnsafeBytes { ptr in
            randomx_init_cache(cache, ptr.baseAddress, seedHash.count)
        }

        // Allocate and init dataset (uses all CPU cores)
        rxDataset = randomx_alloc_dataset(flags)
        guard let dataset = rxDataset else {
            status = "Failed to allocate RandomX dataset"
            return
        }

        let itemCount = randomx_dataset_item_count()
        let cpuCount = UInt32(ProcessInfo.processInfo.processorCount)

        // Initialize dataset in parallel
        DispatchQueue.concurrentPerform(iterations: Int(cpuCount)) { i in
            let start = UInt(i) * (UInt(itemCount) / UInt(cpuCount))
            let count = (i == Int(cpuCount) - 1)
                ? UInt(itemCount) - start
                : UInt(itemCount) / UInt(cpuCount)
            randomx_init_dataset(dataset, cache, start, count)
        }

        status = "RandomX ready"
    }

    private func cleanupRandomX() {
        if let dataset = rxDataset {
            randomx_release_dataset(dataset)
            rxDataset = nil
        }
        if let cache = rxCache {
            randomx_release_cache(cache)
            rxCache = nil
        }
        currentSeedHash = nil
    }

    // MARK: - Mining

    private func handleNewJob(_ job: StratumClient.MiningJob, threads: Int) {
        // Cancel existing workers
        for worker in cpuWorkers { worker.cancel() }
        cpuWorkers.removeAll()

        // Init RandomX with seed hash if needed
        if !job.seedHash.isEmpty {
            initRandomX(seedHash: job.seedHash)
        }

        guard rxDataset != nil else {
            status = "No RandomX dataset"
            return
        }

        status = "Mining"

        // Spawn CPU worker threads
        for threadId in 0..<threads {
            let worker = Task.detached { [weak self] in
                guard let self else { return }
                await self.mineWorker(job: job, threadId: threadId, totalThreads: threads)
            }
            cpuWorkers.append(worker)
        }
    }

    private func mineWorker(job: StratumClient.MiningJob, threadId: Int, totalThreads: Int) async {
        // Each thread gets its own VM
        let flags = randomx_flags(RANDOMX_FLAG_DEFAULT.rawValue | RANDOMX_FLAG_HARD_AES.rawValue | RANDOMX_FLAG_JIT.rawValue | RANDOMX_FLAG_FULL_MEM.rawValue)
        guard let dataset = rxDataset,
              let vm = randomx_create_vm(flags, nil, dataset) else {
            return
        }
        defer { randomx_destroy_vm(vm) }

        var nonce: UInt32 = UInt32(threadId) * (UInt32.max / UInt32(totalThreads))
        var blob = job.blob
        let targetValue = targetToUInt64(job.target)

        while !Task.isCancelled {
            // Set nonce in blob (bytes 39-42 for CryptoNote)
            if blob.count >= 43 {
                blob[39] = UInt8(nonce & 0xFF)
                blob[40] = UInt8((nonce >> 8) & 0xFF)
                blob[41] = UInt8((nonce >> 16) & 0xFF)
                blob[42] = UInt8((nonce >> 24) & 0xFF)
            }

            // Compute RandomX hash
            var hash = Data(count: Int(RANDOMX_HASH_SIZE))
            blob.withUnsafeBytes { inputPtr in
                hash.withUnsafeMutableBytes { hashPtr in
                    randomx_calculate_hash(vm, inputPtr.baseAddress, blob.count, hashPtr.baseAddress)
                }
            }

            await MainActor.run { [weak self] in
                self?.hashCount += 1
            }

            // Check if hash meets target
            let hashValue = hashToUInt64(hash)
            if targetValue > 0 && hashValue < targetValue {
                let nonceHex = String(format: "%08x", nonce)
                let resultHex = hash.hexString()
                await MainActor.run { [weak self] in
                    self?.sharesFound += 1
                    self?.stratum.submitShare(jobId: job.jobId, nonce: nonceHex, result: resultHex)
                }
            }

            nonce &+= 1

            // Yield periodically
            if nonce % 32 == 0 {
                await Task.yield()
            }
        }
    }

    // MARK: - Helpers

    private func targetToUInt64(_ target: Data) -> UInt64 {
        guard target.count >= 4 else { return UInt64.max }
        var value: UInt64 = 0
        for i in 0..<min(target.count, 8) {
            value |= UInt64(target[i]) << (i * 8)
        }
        if target.count == 4 && value > 0 {
            return UInt64.max / (UInt64(0xFFFFFFFF) / value)
        }
        return value
    }

    private func hashToUInt64(_ hash: Data) -> UInt64 {
        guard hash.count >= 32 else { return UInt64.max }
        var value: UInt64 = 0
        for i in 24..<32 {
            value |= UInt64(hash[i]) << ((i - 24) * 8)
        }
        return value
    }

    private func updateHashrate() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastHashTime)
        guard elapsed > 0 else { return }

        let hashes = hashCount - lastHashCount
        let rate = Double(hashes) / elapsed

        if rate >= 1000 {
            hashrate = String(format: "%.1f kH/s", rate / 1000)
        } else {
            hashrate = String(format: "%.1f H/s", rate)
        }

        lastHashCount = hashCount
        lastHashTime = now
    }
}
