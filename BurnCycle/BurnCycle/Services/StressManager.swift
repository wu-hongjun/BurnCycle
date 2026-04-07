import Foundation
import Metal

/// Built-in CPU+GPU stress test — works offline, no dependencies.
/// Uses GCD for CPU load and Metal compute shaders for GPU load.
@MainActor
final class StressManager: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var status: String = "Idle"

    private var cpuTasks: [Task<Void, Never>] = []
    private var gpuTask: Task<Void, Never>?

    // Metal
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?

    init() {
        setupMetal()
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        self.device = device
        self.commandQueue = queue

        let kernel = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void stress(device float *buf [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float v = buf[id];
            for (int i = 0; i < 512; i++) {
                v = sin(v) * cos(v) + tan(v * 0.01);
                v = sqrt(abs(v) + 1.0) * log2(abs(v) + 2.0);
                v = fma(v, v, v);
            }
            buf[id] = v;
        }
        """
        do {
            let library = try device.makeLibrary(source: kernel, options: nil)
            if let function = library.makeFunction(name: "stress") {
                pipelineState = try device.makeComputePipelineState(function: function)
            }
        } catch { }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        status = "Stressing CPU+GPU"

        // CPU stress — one task per core doing heavy math
        let coreCount = ProcessInfo.processInfo.processorCount
        for _ in 0..<coreCount {
            let task = Task.detached(priority: .high) {
                var x: Double = 1.0
                while !Task.isCancelled {
                    for _ in 0..<10000 {
                        x = sin(x) * cos(x) + tan(x * 0.001)
                        x = sqrt(abs(x) + 1.0) * log2(abs(x) + 2.0)
                    }
                }
                _ = x // prevent optimization
            }
            cpuTasks.append(task)
        }

        // GPU stress — continuous Metal compute
        if let device, let commandQueue, let pipelineState {
            let bufSize = 1024 * 1024 * 2 // 2M floats
            var data = (0..<bufSize).map { _ in Float.random(in: -1...1) }
            guard let buffer = device.makeBuffer(bytes: &data, length: bufSize * 4, options: .storageModeShared) else { return }

            let gridSize = MTLSize(width: bufSize, height: 1, depth: 1)
            let threadGroup = MTLSize(width: min(pipelineState.maxTotalThreadsPerThreadgroup, bufSize), height: 1, depth: 1)

            gpuTask = Task.detached {
                while !Task.isCancelled {
                    let cmd = commandQueue.makeCommandBuffer()!
                    let enc = cmd.makeComputeCommandEncoder()!
                    enc.setComputePipelineState(pipelineState)
                    enc.setBuffer(buffer, offset: 0, index: 0)
                    enc.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroup)
                    enc.endEncoding()
                    cmd.commit()
                    await cmd.completed()
                }
            }
        }
    }

    func stop() {
        for task in cpuTasks { task.cancel() }
        cpuTasks.removeAll()
        gpuTask?.cancel()
        gpuTask = nil
        isRunning = false
        status = "Idle"
    }
}
