import Foundation
import Network

/// 基于 Network.framework 的 UDP 通道（视频 5012 / 控制 5013）
final class UDPChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ninebotcast.udp")

    /// 收到仪表回包（控制回应 / KCP ACK）时回调
    var onReceive: ((Data) -> Void)?

    init(host: String, port: UInt16) {
        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            fatalError("非法端口 \(port)")
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: portValue,
            using: .udp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveLoop()
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onReceive?(data)
            }
            if error == nil {
                self.receiveLoop()
            }
        }
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func stop() {
        connection.cancel()
    }
}
