import Foundation
import Metal

/// Metal GPU compute stress engine — runs intensive parallel computation
/// to maximize GPU power draw. Adopted from SiliconMiner's Metal compute pattern.
@MainActor
final class GPUStresser: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var status: String = "Idle"

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var stressTask: Task<Void, Never>?

    private let bufferSize = 1024 * 1024 * 4 // 4M floats = 16MB

    init() {
        setupMetal()
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            status = "No Metal GPU"
            return
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            status = "Failed to create command queue"
            return
        }
        self.commandQueue = queue

        let kernelSource = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void stressKernel(device float *input [[buffer(0)]],
                                 device float *output [[buffer(1)]],
                                 uint id [[thread_position_in_grid]]) {
            float val = input[id];
            for (int i = 0; i < 512; i++) {
                val = sin(val) * cos(val) + tan(val * 0.01);
                val = sqrt(abs(val) + 1.0) * log2(abs(val) + 2.0);
                val = fma(val, val, val);
                val = pow(abs(val) + 0.001, 0.99);
            }
            output[id] = val;
        }
        """

        do {
            let library = try device.makeLibrary(source: kernelSource, options: nil)
            guard let function = library.makeFunction(name: "stressKernel") else {
                status = "Failed to create kernel function"
                return
            }
            pipelineState = try device.makeComputePipelineState(function: function)
            status = "Ready"
        } catch {
            status = "Shader error: \(error.localizedDescription)"
        }
    }

    func start() {
        guard !isRunning else { return }
        guard let device = device,
              let commandQueue = commandQueue,
              let pipelineState = pipelineState else {
            status = "Metal not available"
            return
        }

        isRunning = true
        status = "Running"

        var inputData = [Float](repeating: 0, count: bufferSize)
        for i in 0..<bufferSize {
            inputData[i] = Float.random(in: -1.0...1.0)
        }

        guard let inputBuffer = device.makeBuffer(bytes: inputData,
                                                   length: bufferSize * MemoryLayout<Float>.size,
                                                   options: .storageModeShared),
              let outputBuffer = device.makeBuffer(length: bufferSize * MemoryLayout<Float>.size,
                                                    options: .storageModeShared) else {
            status = "Buffer allocation failed"
            isRunning = false
            return
        }

        let gridSize = MTLSize(width: bufferSize, height: 1, depth: 1)
        let threadGroupSize = MTLSize(
            width: min(pipelineState.maxTotalThreadsPerThreadgroup, bufferSize),
            height: 1, depth: 1
        )
        let bSize = bufferSize

        stressTask = Task.detached {
            while !Task.isCancelled {
                let commandBuffer = commandQueue.makeCommandBuffer()!
                let encoder = commandBuffer.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(pipelineState)
                encoder.setBuffer(inputBuffer, offset: 0, index: 0)
                encoder.setBuffer(outputBuffer, offset: 0, index: 1)
                encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
                encoder.endEncoding()
                commandBuffer.commit()
                await commandBuffer.completed()

                // Swap partial data to prevent compiler optimization
                let src = outputBuffer.contents()
                let dst = inputBuffer.contents()
                memcpy(dst, src, min(1024 * MemoryLayout<Float>.size, bSize * MemoryLayout<Float>.size))
            }
        }
    }

    func stop() {
        stressTask?.cancel()
        stressTask = nil
        isRunning = false
        status = "Stopped"
    }
}
