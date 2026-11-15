import Foundation
import CoreMedia

/// 投屏引擎：帧定时器 → 测试图 → VideoToolbox → RTP 打包 → UDP 5012
/// RTCP ping/pong → UDP 5013（每 1 秒一次，20 字节，协议逆向自官方 APK）
///
/// 与官方 Android 实现对齐的关键点：
/// - 每帧数据 = SPS/PPS(Annex-B) + 帧数据(Annex-B)，逐字节 1380 分片
/// - 时间戳用毫秒；关键帧每秒 1 个；关键帧可选重发一遍
/// - 本地端口绑定 5012/5013
final class CastEngine: ObservableObject {
    @Published var statusText: String = "待机"
    @Published var sentFrames: Int = 0
    @Published var sentPackets: Int = 0
    @Published var rtcpPongCount: Int = 0
    @Published var lastRTTMs: Int = -1
    @Published var dashboardReport: String = ""

    private var preset: DashboardPreset = .fiveInch
    private var videoChannel: UDPChannel?
    private var controlChannel: UDPChannel?
    private var encoder: H264Encoder?
    private var kcpChannel: KCPChannel?
    private var kcpTimer: DispatchSourceTimer?
    private var frameTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0
    private var pingCounter: UInt32 = 0
    private var pingSentTimes: [UInt32: Int] = [:]
    private var duplicateKeyframes = true

    private let frameQueue = DispatchQueue(label: "ninebotcast.frames")
    private let callbackQueue = DispatchQueue(label: "ninebotcast.send")

    // RTP 打包器只在 callbackQueue 上访问
    private var packer: RTPPacker?

    var isRunning: Bool { frameTimer != nil }

    func start(preset: DashboardPreset, host: String, duplicateKeyframes: Bool) {
        guard preset.isImplemented else {
            statusText = "该预设未实现（JPEG 模式待开发）"
            return
        }
        stop()

        self.preset = preset
        self.duplicateKeyframes = duplicateKeyframes
        frameIndex = 0
        pingCounter = 0
        pingSentTimes = [:]

        let localIP = LocalAddress.primaryIPv4()

        let video = UDPChannel(host: host, remotePort: 5012, localIP: localIP, localPort: 5012)
        video.start()
        videoChannel = video

        let control = UDPChannel(host: host, remotePort: 5013, localIP: localIP, localPort: 5013)
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

        // 仪表回包：RTCP pong（官方还有 24 字节回复变体，仅记录）
        control.onReceive = { [weak self] data in
            self?.handleControlReceive(data)
        }
        video.onReceive = { [weak self] data in
            self?.handleControlReceive(data)
        }

        let encoder = H264Encoder()
        guard encoder.setup(
            width: preset.width, height: preset.height,
            fps: preset.fps, bitrate: preset.bitrate) else {
            statusText = "H.264 编码器初始化失败"
            return
        }
        encoder.onAnnexBFrame = { [weak self] data, isKey in
            self?.handleEncodedFrame(data, keyframe: isKey)
        }
        self.encoder = encoder

        callbackQueue.sync {
            packer = RTPPacker()
        }

        // RTCP ping：每 1 秒一次（官方节奏），计数器从 1 开始
        let ping = DispatchSource.makeTimerSource(queue: callbackQueue)
        ping.schedule(deadline: .now() + 0.5, repeating: .seconds(1))
        ping.setEventHandler { [weak self] in
            self?.sendPing()
        }
        ping.resume()
        pingTimer = ping

        // 帧定时器
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(preset.fps))
        timer.setEventHandler { [weak self] in self?.produceFrame() }
        timer.resume()
        frameTimer = timer

        statusText = "发送中 → \(host)\(localIP.map { "（本机 \($0):5012/5013）" } ?? "")：\(preset.title)"
        sentFrames = 0
        sentPackets = 0
        rtcpPongCount = 0
        lastRTTMs = -1
    }

    func stop() {
        frameTimer?.cancel(); frameTimer = nil
        pingTimer?.cancel(); pingTimer = nil
        kcpTimer?.cancel(); kcpTimer = nil
        callbackQueue.sync { packer = nil }
        kcpChannel = nil
        encoder?.teardown()
        encoder = nil
        videoChannel?.stop(); videoChannel = nil
        controlChannel?.stop(); controlChannel = nil
        if statusText.hasPrefix("发送中") {
            statusText = "已停止"
        }
    }

    private func sendPing() {
        pingCounter &+= 1
        let now = Int(Date().timeIntervalSince1970 * 1000)
        callbackQueue.sync {
            pingSentTimes[pingCounter] = now
            if pingSentTimes.count > 16 {
                pingSentTimes.removeValue(forKey: pingSentTimes.keys.first!)
            }
        }
        controlChannel?.send(RTCP.ping(counter: pingCounter))
    }

    private func produceFrame() {
        guard let encoder else { return }
        guard let pixelBuffer = TestImageSource.makeFrame(
            index: frameIndex,
            width: preset.width,
            height: preset.height) else { return }
        frameIndex &+= 1
        let time = CMTime(value: frameIndex, timescale: preset.fps)
        encoder.encode(pixelBuffer, presentationTime: time)
    }

    private func handleEncodedFrame(_ annexB: Data, keyframe: Bool) {
        callbackQueue.sync {
            guard packer != nil else { return }
            guard !annexB.isEmpty else { return }

            // 时间戳：毫秒（帧序号 × 1000 / fps）
            let timestampMs = UInt32((frameIndex * 1000) / Int64(preset.fps))
            let packets = packer!.packetizeFrame(annexB, timestampMs: timestampMs, isKeyframe: keyframe)
            let copies = (keyframe && duplicateKeyframes) ? 2 : 1
            for _ in 0..<copies {
                for packet in packets {
                    if let kcp = kcpChannel {
                        kcp.send(packet)
                    } else {
                        videoChannel?.send(packet)
                    }
                }
            }

            DispatchQueue.main.async {
                self.sentFrames += 1
                self.sentPackets += packets.count * copies
            }
        }
    }

    private func handleControlReceive(_ data: Data) {
        if let seq = RTCP.parsePong(data) {
            var sentAt: Int? = nil
            callbackQueue.sync {
                sentAt = pingSentTimes.removeValue(forKey: seq)
            }
            DispatchQueue.main.async {
                self.rtcpPongCount += 1
                if let sentAt {
                    self.lastRTTMs = Int(Date().timeIntervalSince1970 * 1000) - sentAt
                }
            }
            return
        }
        // 仪表主动报告：1=丢包 2=请求帧率 3=请求码率
        if let report = RTCP.parseApp(data) {
            DispatchQueue.main.async {
                switch report.subtype {
                case 1:
                    self.dashboardReport = "仪表丢包报告 #\(report.value ?? 0)"
                case 2:
                    self.dashboardReport = "仪表请求帧率 \(report.value ?? 0) FPS"
                case 3:
                    if let rate = report.value {
                        self.dashboardReport = "仪表请求码率 \(rate / 1000) kbps（已应用）"
                        self.encoder?.updateBitrate(rate)
                    }
                default:
                    break
                }
            }
            return
        }
        // 其他回包只记日志
        if data.count != 20 {
            NSLog("仪表回包 \(data.count) 字节: %@", data.map { String(format: "%02x", $0) }.joined())
        }
    }
}
