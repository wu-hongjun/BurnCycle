import Foundation
import Network

/// Minimal Stratum v1 client for Monero mining pool communication.
/// Handles login, job reception, and share submission over TCP+TLS.
@MainActor
final class StratumClient: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var status: String = "Disconnected"
    @Published var currentJob: MiningJob?

    private var connection: NWConnection?
    private var requestId: Int = 1
    private var buffer = Data()
    var onNewJob: ((MiningJob) -> Void)?

    struct MiningJob {
        let jobId: String
        let blob: Data
        let target: Data
        let seedHash: Data
        let height: UInt64
    }

    func connect(host: String, port: UInt16, wallet: String, useTLS: Bool = true) {
        let tlsOptions: NWProtocolTLS.Options? = useTLS ? NWProtocolTLS.Options() : nil
        let tcpOptions = NWProtocolTCP.Options()

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.status = "Connected"
                    self?.login(wallet: wallet)
                case .failed(let error):
                    self?.isConnected = false
                    self?.status = "Error: \(error.localizedDescription)"
                case .waiting(let error):
                    self?.status = "Waiting: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }

        connection?.start(queue: .global(qos: .userInitiated))
        startReceiving()
        status = "Connecting..."
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        status = "Disconnected"
        currentJob = nil
    }

    private func login(wallet: String) {
        let id = nextId()
        let request: [String: Any] = [
            "id": id,
            "jsonrpc": "2.0",
            "method": "login",
            "params": [
                "login": wallet,
                "pass": "x",
                "rigid": "",
                "agent": "BatteryBurner/1.0"
            ]
        ]
        send(request)
    }

    func submitShare(jobId: String, nonce: String, result: String) {
        let id = nextId()
        let request: [String: Any] = [
            "id": id,
            "jsonrpc": "2.0",
            "method": "submit",
            "params": [
                "id": "",
                "job_id": jobId,
                "nonce": nonce,
                "result": result
            ]
        ]
        send(request)
    }

    private func send(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let connection = connection else { return }
        var payload = data
        payload.append(0x0A) // newline delimiter
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let data = content {
                Task { @MainActor in
                    self?.buffer.append(data)
                    self?.processBuffer()
                }
            }
            if !isComplete && error == nil {
                Task { @MainActor in
                    self?.startReceiving()
                }
            }
        }
    }

    private func processBuffer() {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            handleMessage(json)
        }
    }

    private func handleMessage(_ json: [String: Any]) {
        // Check for job in login response
        if let result = json["result"] as? [String: Any],
           let job = result["job"] as? [String: Any] {
            parseJob(job)
            return
        }

        // Check for new job notification
        if let method = json["method"] as? String, method == "job",
           let params = json["params"] as? [String: Any] {
            parseJob(params)
            return
        }

        // Check for share acceptance
        if let result = json["result"] as? [String: Any],
           let status = result["status"] as? String {
            if status == "OK" {
                self.status = "Share accepted"
            }
        }

        // Check for errors
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            status = "Error: \(message)"
        }
    }

    private func parseJob(_ job: [String: Any]) {
        guard let jobId = job["job_id"] as? String,
              let blobHex = job["blob"] as? String,
              let targetHex = job["target"] as? String else { return }

        let seedHash = (job["seed_hash"] as? String) ?? ""
        let height = (job["height"] as? UInt64) ?? 0

        let miningJob = MiningJob(
            jobId: jobId,
            blob: Data(hexString: blobHex) ?? Data(),
            target: Data(hexString: targetHex) ?? Data(),
            seedHash: Data(hexString: seedHash) ?? Data(),
            height: height
        )

        currentJob = miningJob
        status = "New job: \(jobId.prefix(8))..."
        onNewJob?(miningJob)
    }

    private func nextId() -> Int {
        let id = requestId
        requestId += 1
        return id
    }
}

// MARK: - Hex string helpers

extension Data {
    init?(hexString: String) {
        let hex = hexString.dropFirst(hexString.hasPrefix("0x") ? 2 : 0)
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    func hexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
