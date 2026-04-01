import Foundation
import Accelerate

/// Apple Neural Engine / AMX stress engine — runs intensive matrix operations
/// through Accelerate/BLAS to saturate the AMX coprocessor and ANE.
@MainActor
final class ANEStresser: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var status: String = "Idle"

    private var stressTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        status = "Running"

        stressTask = Task.detached {
            let size = 2048
            let count = size * size

            var matA = [Float](repeating: 0, count: count)
            var matB = [Float](repeating: 0, count: count)
            var matC = [Float](repeating: 0, count: count)

            for i in 0..<count {
                matA[i] = Float.random(in: -1.0...1.0)
                matB[i] = Float.random(in: -1.0...1.0)
            }

            let sizeLen = vDSP_Length(size)

            while !Task.isCancelled {
                // Large matrix multiply via vDSP — dispatched to AMX coprocessor on Apple Silicon
                vDSP_mmul(matA, 1, matB, 1, &matC, 1, sizeLen, sizeLen, sizeLen)

                // vDSP operations for additional stress
                var result = [Float](repeating: 0, count: count)
                vDSP_vsq(matC, 1, &result, 1, vDSP_Length(count))
                vDSP_vabs(result, 1, &matB, 1, vDSP_Length(count))

                // Feed result back to prevent optimization
                for i in 0..<min(count, 1024) {
                    matA[i] = matC[i].truncatingRemainder(dividingBy: 1.0)
                }

                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms yield
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
