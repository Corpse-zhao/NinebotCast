import Foundation
import Network

/// 基于 Network.framework 的 UDP 通道（视频 5012 / RTCP 5013）。
/// 官方实现会把本地端口也绑到 5012/5013，这里保持一致。
final class UDPChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ninebotcast.udp")

    /// 收到仪表回包（RTCP pong / 其他控制回应）时回调
    var onReceive: ((Data) -> Void)?

    init(host: String, remotePort: UInt16, localIP: String? = nil, localPort: UInt16? = nil) {
        // 端口非法时退回默认值，不用 fatalError（宁可发不出去也不要闪退）
        let portValue = NWEndpoint.Port(rawValue: remotePort) ?? 5012
        let params = NWParameters.udp
        if let localIP, let localPort, let lp = NWEndpoint.Port(rawValue: localPort) {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(localIP), port: lp)
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: portValue,
            using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLoop()
            case .failed(let error):
                Diag.log("UDP 失败 \(error)")
            case .waiting(let error):
                Diag.log("UDP 等待 \(error)")
            default:
                break
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
