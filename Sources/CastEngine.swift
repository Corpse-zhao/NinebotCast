import Foundation
import CoreMedia

/// 投屏引擎：帧定时器 → 测试图 → VideoToolbox → RTP 打包 → UDP 5012
/// 控制与保活 → UDP 5013（心跳字节格式待抓包核对，骨架阶段先发占位包）
final class CastEngine: ObservableObject {
    @Published var statusText: String = "待机"
    @Published var sentFrames: Int = 0
    @Published var sentPackets: Int = 0

    private var preset: DashboardPreset = .fiveInch
    private var videoChannel: UDPChannel?
    private var controlChannel: UDPChannel?
    private var encoder: H264Encoder?
    private var kcpChannel: KCPChannel?
    private var kcpTimer: DispatchSourceTimer?
    private var frameTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0

    private let frameQueue = DispatchQueue(label: "ninebotcast.frames")
    private let callbackQueue = DispatchQueue(label: "ninebotcast.send")

    // RTP 打包器只在 callbackQueue 上访问
    private var packer: RTPPacker?

    var isRunning: Bool { frameTimer != nil }

    func start(preset: DashboardPreset, host: String) {
        guard preset.isImplemented else {
            statusText = "该预设未实现（JPEG 模式待开发）"
            return
        }
        stop()

        self.preset = preset
        frameIndex = 0

        let video = UDPChannel(host: host, port: 5012)
        video.start()
        videoChannel = video

        let control = UDPChannel(host: host, port: 5013)
        control.start()
        controlChannel = control

        // 七寸：视频 RTP 包先过 KCP 再走 UDP
        if preset.codec == .h264kcp {
            let kcp = KCPChannel(conv: preset.kcpConv) { [weak video] data in
                video?.send(data)
            }
            kcpChannel = kcp
            let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { kcp.tick() }
            timer.resume()
            kcpTimer = timer
        }

        // 仪表回包（控制回应 / KCP ACK）
        video.onReceive = { [weak self] data in
            self?.handleReceive(data)
        }
        control.onReceive = { [weak self] data in
            self?.handleReceive(data)
        }

        let encoder = H264Encoder()
        guard encoder.setup(
            width: preset.width, height: preset.height,
            fps: preset.fps, bitrate: preset.bitrate) else {
            statusText = "H.264 编码器初始化失败"
            return
        }
        encoder.onAnnexBFrame = { [weak self] data, _ in
            self?.handleEncodedFrame(data)
        }
        self.encoder = encoder

        callbackQueue.sync {
            packer = RTPPacker(payloadType: preset.rtpPayloadType)
        }

        // 心跳/控制：字节格式待抓包核对，先发 1 字节占位
        let heartbeat = DispatchSource.makeTimerSource(queue: callbackQueue)
        heartbeat.schedule(deadline: .now(), repeating: .milliseconds(500))
        heartbeat.setEventHandler { [weak self] in
            self?.controlChannel?.send(Data([0x00]))
        }
        heartbeat.resume()
        heartbeatTimer = heartbeat

        // 帧定时器
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(preset.fps))
        timer.setEventHandler { [weak self] in self?.produceFrame() }
        timer.resume()
        frameTimer = timer

        statusText = "发送中 → \(host)：\(preset.title)，请看仪表画面"
        sentFrames = 0
        sentPackets = 0
    }

    func stop() {
        frameTimer?.cancel(); frameTimer = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        kcpTimer?.cancel(); kcpTimer = nil
        callbackQueue.sync { packer = nil }
        kcpChannel = nil
        encoder?.teardown()
        encoder = nil
        videoChannel?.stop(); videoChannel = nil
        controlChannel?.stop(); controlChannel = nil
        if isRunning || statusText.hasPrefix("发送中") {
            statusText = "已停止"
        }
    }

    private func produceFrame() {
        guard let encoder else { return }
        guard let pixelBuffer = TestImageSource.makeFrame(
            index: frameIndex,
            width: preset.width,
            height: preset.height) else { return }
        frameIndex &+= 1
        let time = CMTime(value: CMInt64(frameIndex), timescale: preset.fps)
        encoder.encode(pixelBuffer, presentationTime: time)
    }

    private func handleEncodedFrame(_ annexB: Data) {
        callbackQueue.sync {
            guard let selfPacker = packer else { return }
            let nalus = AnnexB.split(annexB)
            guard !nalus.isEmpty else { return }
            let packets = selfPacker.packetizeFrame(nalus: nalus, fps: preset.fps)

            if let kcp = kcpChannel {
                for packet in packets { kcp.send(packet) }
            } else {
                for packet in packets { videoChannel?.send(packet) }
            }

            DispatchQueue.main.async {
                self.sentFrames += 1
                self.sentPackets += packets.count
            }
        }
    }

    private func handleReceive(_ data: Data) {
        // TODO: 抓包核对 5013 回应（README 提到七寸有 24 字节回复）
        kcpChannel?.input(data)
        NSLog("仪表回包 \(data.count) 字节: %@", data.map { String(format: "%02x", $0) }.joined())
    }
}
