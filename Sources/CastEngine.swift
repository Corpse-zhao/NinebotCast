import Foundation
import CoreMedia
import UIKit
import AVFoundation

/// 投屏引擎：帧定时器 → 测试图 → VideoToolbox → RTP 打包 → UDP 5012
/// RTCP ping/pong 走 UDP 5013（每 1 秒一次，20 字节，逆向自官方 APK）
///
/// 与官方 Android 实现对齐的关键点：
/// - 每帧数据 = SPS/PPS(Annex-B) + 帧数据(Annex-B)，逐字节 1380 分片
/// - 时间戳用毫秒；关键帧每秒 1 个；关键帧可选重发一遍
/// - 本地端口绑定 5012/5013
///
/// 防闪退相关：
/// - 所有对 callbackQueue 的访问都走 `onSendQueue`，本身就带 specific key 检测，
///   不会再出现「在 callbackQueue 上再 sync 自己」的自锁死
/// - 编码器实例退役后不释放（留在 retiredEncoders 里），
///   保证 VideoToolbox 的 refcon 指针永远有效，不会 use-after-free
final class CastEngine: ObservableObject {
    @Published var statusText: String = "待机"
    @Published var sentFrames: Int = 0
    @Published var sentPackets: Int = 0
    @Published var rtcpPongCount: Int = 0
    @Published var lastRTTMs: Int = -1
    @Published var dashboardReport: String = ""
    @Published var localIPText: String = "-"
    @Published var isRunning: Bool = false

    private var preset: DashboardPreset = .fiveInch
    private var videoChannel: UDPChannel?
    private var controlChannel: UDPChannel?
    private var encoder: H264Encoder?
    private var retiredEncoders: [H264Encoder] = []
    private var kcpChannel: KCPChannel?
    private var kcpTimer: DispatchSourceTimer?
    private var frameTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0
    private var encodedFrameIndex: Int64 = 0
    private var pingCounter: UInt32 = 0
    private var pingSentTimes: [UInt32: Int] = [:]
    private var duplicateKeyframes = true
    /// 画面源：测试图 / 相册图片 / 相册视频（循环）/ 摄像头
    private var photoImage: UIImage?
    private var photoRotation = 0
    private var photoBuffer: CVPixelBuffer?
    private var videoSource: VideoFrameSource?
    private var cameraSource: CameraSource?
    private var cameraRotation = 0

    private let frameQueue = DispatchQueue(label: "ninebotcast.frames")
    private let callbackQueue = DispatchQueue(label: "ninebotcast.send")
    private let queueKey = DispatchSpecificKey<Int>()

    // RTP 打包器只在 callbackQueue 上访问
    private var packer: RTPPacker?

    init() {
        callbackQueue.setSpecific(key: queueKey, value: 1)
    }

    /// 选一张相册图片当画面源；传 nil 回到测试图
    func setPhoto(_ image: UIImage?) {
        usePhoto(image, rotation: photoRotation)
    }

    private func rebuildPhotoBuffer() {
        guard let photoImage else {
            photoBuffer = nil
            return
        }
        photoBuffer = FrameRenderer.drawImage(
            photoImage, rotation: photoRotation,
            width: preset.width, height: preset.height)
    }

    private func teardownSources() {
        videoSource?.stop()
        videoSource = nil
        cameraSource?.stop()
        cameraSource = nil
        photoBuffer = nil
        photoImage = nil
    }

    /// 回到内置测试图
    func useTestImage() {
        teardownSources()
        Diag.log("画面源：测试图")
    }

    /// 相册图片（静态，铺满 + 可旋转）
    func usePhoto(_ image: UIImage?, rotation: Int) {
        teardownSources()
        guard let image else {
            Diag.log("画面源：测试图")
            return
        }
        photoImage = image
        photoRotation = rotation
        rebuildPhotoBuffer()
        Diag.log("画面源：图片 rot=\(rotation) → \(preset.width)x\(preset.height)")
    }

    /// 相册视频（循环播放，铺满 + 可旋转），独立线程解码，不阻塞发送
    func useVideo(url: URL, rotation: Int) {
        teardownSources()
        let source = VideoFrameSource(url: url, width: preset.width, height: preset.height,
                                      rotation: rotation, fps: Int(preset.fps))
        source.start()
        videoSource = source
        Diag.log("画面源：视频 \(url.lastPathComponent) rot=\(rotation)")
    }

    /// 摄像头（铺满 + 可旋转）
    func useCamera(position: AVCaptureDevice.Position, rotation: Int) {
        teardownSources()
        cameraRotation = rotation
        let source = CameraSource()
        source.start(position: position) { [weak self] error in
            if let error {
                Diag.log("摄像头启动失败：\(error)")
                DispatchQueue.main.async {
                    self?.dashboardReport = "摄像头启动失败：\(error)"
                }
            }
        }
        cameraSource = source
    }

    /// - Parameter pingOnly: 只发 RTCP ping，不建编码器、不发视频。用于隔离闪退原因。
    /// - Parameter packetSize: RTP 分片大小（官方 1400 / APK 1380）
    /// - Parameter gop: 关键帧间隔（官方 gopSize=10）
    func start(preset: DashboardPreset,
               host: String,
               duplicateKeyframes: Bool,
               packetSize: Int = 1400,
               gop: Int = 10,
               pingOnly: Bool = false) {
        guard preset.isImplemented || pingOnly else {
            statusText = "该预设未实现（JPEG 模式待开发）"
            return
        }
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            statusText = "仪表 IP 为空"
            return
        }
        guard preset.fps > 0 else {
            statusText = "预设帧率非法"
            return
        }

        stop()

        self.preset = preset
        self.duplicateKeyframes = duplicateKeyframes
        frameIndex = 0
        encodedFrameIndex = 0
        pingCounter = 0
        pingSentTimes = [:]
        rebuildPhotoBuffer()   // 预设变了，图片要按新尺寸重画

        let localIP = LocalAddress.primaryIPv4()
        localIPText = localIP ?? "（没取到 Wi-Fi 地址）"
        if let localIP, localIP == target {
            statusText = "填的是本机地址，仪表 IP 不是这个"
            Diag.log("start 中止：host 与本机 IP 相同 \(target)")
            return
        }
        Diag.log("start preset=\(preset.id) host=\(target) local=\(localIP ?? "nil") pingOnly=\(pingOnly)")

        let video = UDPChannel(host: target, remotePort: 5012, localIP: localIP, localPort: 5012)
        video.start()
        videoChannel = video

        let control = UDPChannel(host: target, remotePort: 5013, localIP: localIP, localPort: 5013)
        control.start()
        controlChannel = control

        // 七寸：视频 RTP 包先过 KCP 再走 UDP
        if preset.codec == .h264kcp && !pingOnly {
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

        control.onReceive = { [weak self] data in
            self?.handleControlReceive(data)
        }
        video.onReceive = { [weak self] data in
            self?.handleControlReceive(data)
        }
        // 本机 5012/5013 被九号出行占用时的降级提示（onFallback 已在主线程）
        let fallbackNote: (String) -> Void = { [weak self] note in
            self?.dashboardReport = note
            Diag.log(note)
        }
        video.onFallback = fallbackNote
        control.onFallback = fallbackNote

        if !pingOnly {
            let encoder = H264Encoder()
            guard encoder.setup(
                width: preset.width, height: preset.height,
                fps: preset.fps, bitrate: preset.bitrate, gop: gop) else {
                statusText = "H.264 编码器初始化失败（看诊断日志）"
                return
            }
            encoder.onAnnexBFrame = { [weak self] data, isKey in
                self?.handleEncodedFrame(data, keyframe: isKey)
            }
            self.encoder = encoder

            onSendQueue { packer = RTPPacker(chunkSize: packetSize) }
        }

        // RTCP ping：每 1 秒一次（官方节奏），计数器从 1 开始
        let ping = DispatchSource.makeTimerSource(queue: callbackQueue)
        ping.schedule(deadline: .now() + 0.3, repeating: .seconds(1))
        ping.setEventHandler { [weak self] in
            self?.sendPing()
        }
        ping.resume()
        pingTimer = ping

        if !pingOnly {
            let timer = DispatchSource.makeTimerSource(queue: frameQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(preset.fps))
            timer.setEventHandler { [weak self] in self?.produceFrame() }
            timer.resume()
            frameTimer = timer
        }

        sentFrames = 0
        sentPackets = 0
        rtcpPongCount = 0
        lastRTTMs = -1
        dashboardReport = ""
        statusText = pingOnly
            ? "仅 RTCP ping → \(target):5013（不编码、不发画面）"
            : "发送中 → \(target):5012\(localIP.map { "（本机 \($0)）" } ?? "")：\(preset.title)"
        isRunning = true
        BackgroundKeeper.shared.start()   // 退后台不断流（静音音频保活 + 禁止锁屏）
        Diag.log("start 完成")
    }

    func stop() {
        frameTimer?.cancel(); frameTimer = nil
        pingTimer?.cancel(); pingTimer = nil
        kcpTimer?.cancel(); kcpTimer = nil
        onSendQueue { packer = nil }
        kcpChannel = nil
        isRunning = false

        if let encoder {
            // 先摘回调再失效，最后把实例留在数组里保活（refcon 不能悬垂）
            encoder.onAnnexBFrame = nil
            encoder.teardown()
            retiredEncoders.append(encoder)
            if retiredEncoders.count > 6 {
                retiredEncoders.removeFirst()
            }
        }
        self.encoder = nil

        videoChannel?.stop(); videoChannel = nil
        controlChannel?.stop(); controlChannel = nil
        BackgroundKeeper.shared.stop()

        if statusText.hasPrefix("发送中") || statusText.hasPrefix("仅 RTCP") {
            statusText = "已停止"
        }
        if pingCounter > 0 {
            Diag.log("stop：累计 \(sentFrames) 帧 / \(sentPackets) 包，pong \(rtcpPongCount) 次")
        }
    }

    /// 统一走这里访问 callbackQueue：已在队列上就直接执行，不会自锁死
    private func onSendQueue(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
            return
        }
        callbackQueue.sync(execute: block)
    }

    private func sendPing() {
        pingCounter &+= 1
        pingSentTimes[pingCounter] = Int(Date().timeIntervalSince1970 * 1000)
        if pingSentTimes.count > 16 {
            pingSentTimes.removeValue(forKey: pingSentTimes.keys.first!)
        }
        // 官方心跳（APP 子类型 5，参数 [0,2]）先发；再发计数变体兜底，两包都无害
        controlChannel?.send(RTCP.heartbeat())
        controlChannel?.send(RTCP.ping(counter: pingCounter))
        if pingCounter == 1 {
            Diag.log("首个心跳已发出（官方 [0,2] + 计数变体）")
        }
    }

    private func produceFrame() {
        autoreleasepool {
            guard let encoder else { return }
            // 视频源：拿解码线程最新产出的帧（解码独立进行，发送端零等待）
            if let videoSource, let buffer = videoSource.latestFrame() {
                frameIndex &+= 1
                encoder.encode(buffer,
                               presentationTime: CMTime(value: frameIndex, timescale: preset.fps))
                return
            }
            // 摄像头：取最新帧（后台采集停止时自动停在最后一帧，流不断）
            if let cameraSource, let buffer = cameraSource.renderedFrame(
                width: preset.width, height: preset.height, rotation: cameraRotation) {
                frameIndex &+= 1
                encoder.encode(buffer,
                               presentationTime: CMTime(value: frameIndex, timescale: preset.fps))
                return
            }
            // 图片：每帧重复编码同一张
            if let photoBuffer {
                frameIndex &+= 1
                encoder.encode(photoBuffer,
                               presentationTime: CMTime(value: frameIndex, timescale: preset.fps))
                return
            }
            guard let pixelBuffer = TestImageSource.makeFrame(
                index: frameIndex,
                width: preset.width,
                height: preset.height) else { return }
            frameIndex &+= 1
            let time = CMTime(value: frameIndex, timescale: preset.fps)
            encoder.encode(pixelBuffer, presentationTime: time)
        }
    }

    private func handleEncodedFrame(_ annexB: Data, keyframe: Bool) {
        autoreleasepool {
            onSendQueue {
                // 取出 → 改动 → 写回（packetizeFrame 是 mutating，走可选链容易踩编译/语义坑）
                guard var currentPacker = packer, !annexB.isEmpty else { return }

                // 时间戳：毫秒（已编码帧序号 × 1000 / fps）；用编码侧计数避免跨队列竞争
                encodedFrameIndex &+= 1
                let timestampMs = UInt32((encodedFrameIndex * 1000) / Int64(preset.fps))
                let packets = currentPacker.packetizeFrame(
                    annexB, timestampMs: timestampMs, isKeyframe: keyframe)
                packer = currentPacker
                guard !packets.isEmpty else { return }

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

                let frameBytes = annexB.count
                let packetCount = packets.count * copies
                DispatchQueue.main.async {
                    self.sentFrames += 1
                    self.sentPackets += packetCount
                    if self.sentFrames == 1 {
                        Diag.log("首帧已发：\(frameBytes) 字节 → \(packetCount) 包 key=\(keyframe)")
                    }
                }
            }
        }
    }

    private func handleControlReceive(_ data: Data) {
        if let seq = RTCP.parsePong(data) {
            var sentAt: Int? = nil
            onSendQueue {
                sentAt = pingSentTimes.removeValue(forKey: seq)
            }
            DispatchQueue.main.async {
                self.rtcpPongCount += 1
                if let sentAt {
                    self.lastRTTMs = Int(Date().timeIntervalSince1970 * 1000) - sentAt
                }
                if self.rtcpPongCount == 1 {
                    Diag.log("收到第一个 pong：仪表在线且认 RTCP")
                }
            }
            return
        }
        // 仪表主动报告：1=丢包 2=请求帧率 3=请求码率
        if let report = RTCP.parseApp(data) {
            Diag.log("仪表报告 subtype=\(report.subtype) value=\(report.value ?? 0)")
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
        if data.count != 20 {
            Diag.log("仪表回包 \(data.count) 字节 \(data.prefix(24).map { String(format: "%02x", $0) }.joined())")
        }
    }
}
