import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import VideoToolbox

/// CarPlay（OpenXPlay / OXP）画面源。
///
/// 链路：iPhone 上装 OpenXPlay App（作为 CarPlay 接收端）→ App 起本地
/// WebSocket 服务 `ws://IP:9888/oxp/v0` → 本类连上去发 `hello` 握手 →
/// 收 `video-format`（base64 avcC）建 VideoToolbox 解码器 → 收 24 字节头 +
/// AVCC（4 字节 NAL 长度前缀）整帧 → 解码 → CI 渲染（旋转 + 铺满）到
/// 仪表分辨率 → 5 块缓冲池轮换，latestFrame() 供发送端按固定 fps 轮询。
///
/// 协议细节全部来自 OpenXPlay-Stream 开源仓库源码确认（见技能
/// carplay-oxp-casting / references/oxp-protocol.md）：
/// - 首条消息必须是 hello JSON，token 不校验
/// - 服务端回 welcome → video-format（中途参数变化会再推一条）
/// - 二进制帧头：[0]=kind(1=视频) [1]=stream [2]=flags(bit0 关键帧) [3]=0
///   [4..7]=sequence u32LE [8..15]=ptsUs i64LE [16..23]=senderClockUs i64LE
/// - payload 是 AVCC 整帧，服务端硬校验 4 字节长度前缀
/// - 客户端可发 keyframe 请求、pong（响应服务端 ping）
final class OXPFrameSource: NSObject, URLSessionWebSocketDelegate {

    var onStatus: ((String) -> Void)?

    private let host: String
    private let port: Int
    private let width: Int
    private let height: Int
    private let rotation: Int

    private let lock = NSLock()              // 保护 latestBuffer / 解码器 / 会话
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var formatDesc: CMVideoFormatDescription?
    private var decoderSession: VTDecompressionSession?
    private var outputBoxCtx: UnsafeMutableRawPointer?

    private var destBuffers: [CVPixelBuffer] = []
    private var destIndex = 0
    private var latestBuffer: CVPixelBuffer?
    private let ciContext = CIContext(options: nil)

    private(set) var running = false
    private var reconnectAttempt = 0
    private var reconnectTimer: DispatchSourceTimer?
    private var keyframeTimer: DispatchSourceTimer?
    private var srcWidth = 0
    private var srcHeight = 0
    private var receivedFirstFrame = false
    private var decodedCount = 0

    init(host: String, port: Int, width: Int, height: Int, rotation: Int) {
        self.host = host
        self.port = port
        self.width = width
        self.height = height
        self.rotation = rotation
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        reconnectAttempt = 0
        connect()
    }

    func stop() {
        running = false
        lock.lock()
        teardownDecoderLocked()
        lock.unlock()
        reconnectTimer?.cancel(); reconnectTimer = nil
        keyframeTimer?.cancel(); keyframeTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        task = nil
        lock.lock()
        latestBuffer = nil
        lock.unlock()
        Diag.log("OXP 源已停止（解码 \(decodedCount) 帧）")
    }

    /// 发送线程调用：拿最新解码渲染好的帧
    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestBuffer
    }

    // MARK: - 连接

    private func connect() {
        guard running else { return }
        lock.lock()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let url = URL(string: "ws://\(host):\(port)/oxp/v0")!
        let t = s.webSocketTask(with: url)
        session = s
        task = t
        lock.unlock()
        report("正在连接 OpenXPlay \(host):\(port)…")
        Diag.log("OXP 连接 ws://\(host):\(port)/oxp/v0")
        t.resume()
        receiveLoop()
    }

    private func scheduleReconnect(_ why: String) {
        guard running else { return }
        lock.lock()
        teardownDecoderLocked()
        lock.unlock()
        reconnectAttempt += 1
        let delay = min(8.0, pow(2.0, Double(reconnectAttempt - 1)))
        report("连接断开（\(why)），\(Int(delay)) 秒后重连")
        Diag.log("OXP 断开：\(why)，重连 #\(reconnectAttempt) in \(Int(delay))s")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.connect()
        }
        timer.resume()
        reconnectTimer?.cancel()
        reconnectTimer = timer
    }

    // URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        sendHello()
        startKeyframeNag()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        scheduleReconnect("close \(closeCode.rawValue)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil, running {
            scheduleReconnect(error?.localizedDescription ?? "error")
        }
    }

    // MARK: - 握手

    private func sendHello() {
        // hello 结构按 OpenXPlay-Stream 服务端校验逐字段写；token 不校验传空
        let hello: [String: Any] = [
            "type": "hello",
            "version": 0,
            "token": "",
            "videoCodec": "H264",
            "decoders": [["codecString": "h264", "hardware": true]],
            "displays": [[
                "screen": 0,
                "width": width,
                "height": height,
                "dpr": 1,
                "refreshHz": 30,
                "safeArea": ["top": 0, "bottom": 0, "left": 0, "right": 0]
            ]],
            "maxTouchContacts": 0,
            "audio": [],
            "microphone": false
        ]
        guard JSONSerialization.isValidJSONObject(hello),
              let data = try? JSONSerialization.data(withJSONObject: hello) else {
            Diag.log("OXP hello 序列化失败")
            return
        }
        task?.send(.data(data)) { [weak self] error in
            if let error {
                Diag.log("OXP hello 发送失败：\(error.localizedDescription)")
            } else {
                self?.report("已连接，等待视频格式…")
                Diag.log("OXP hello 已发出")
            }
        }
    }

    /// 解码器没建好 / 还没出首帧前，每 2 秒要一次关键帧
    private func startKeyframeNag() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.lock.lock()
            let wantKey = self.formatDesc != nil && !self.receivedFirstFrame
            self.lock.unlock()
            if wantKey {
                self.sendText(["type": "keyframe", "screen": 0])
            }
        }
        timer.resume()
        keyframeTimer?.cancel()
        keyframeTimer = timer
    }

    private func sendText(_ json: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        task?.send(.data(data)) { _ in }
    }

    private func report(_ msg: String) {
        onStatus?(msg)
    }

    // MARK: - 接收循环

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if self.running {
                    self.scheduleReconnect(error.localizedDescription)
                }
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleText(text)
                case .data(let data):
                    self.handleBinary(data)
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "welcome":
            Diag.log("OXP welcome clientId=\(obj["clientId"] ?? "-")")
        case "video-format":
            handleVideoFormat(obj)
        case "ping":
            // 服务端 ping → 回 pong（带它给的 t0Us + 本地 t1/t2 微秒）
            let nowUs = Int64(Date().timeIntervalSince1970 * 1_000_000)
            let t0 = obj["t0Us"] as? Int64 ?? 0
            sendText(["type": "pong", "t0Us": t0, "t1Us": nowUs, "t2Us": nowUs])
        case "pause":
            Diag.log("OXP pause=\(obj["paused"] ?? "-")")
        default:
            Diag.log("OXP 消息 type=\(type)")
        }
    }

    private func handleVideoFormat(_ obj: [String: Any]) {
        guard let format = obj["format"] as? [String: Any],
              let configB64 = format["config"] as? String,
              let avcC = Data(base64Encoded: configB64) else {
            Diag.log("OXP video-format 缺 config")
            return
        }
        let w = format["width"] as? Int ?? 0
        let h = format["height"] as? Int ?? 0
        let fpsHint = format["fpsHint"] as? Int ?? 0
        lock.lock()
        teardownDecoderLocked()
        guard let (sps, pps) = Self.parseAvcC(avcC) else {
            lock.unlock()
            Diag.log("OXP avcC 解析失败 \(avcC.count) 字节")
            return
        }
        // CMVideoFormatDescriptionCreateFromH264ParameterSets 需要稳定的指针数组：
        // 把 SPS/PPS 定住为 CFData，再取字节指针
        let cfDatas: [CFData] = [sps, pps].map { d in
            d.withUnsafeBytes { raw in
                CFDataCreate(nil, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count)
            }
        }
        var ptrs: [UnsafePointer<UInt8>?] = cfDatas.map { CFDataGetBytePtr($0) }
        var sizes: [Int] = cfDatas.map { CFDataGetLength($0) }
        var fmt: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: &ptrs,
            parameterSetSizes: &sizes,
            naluLengthFrameSize: 4,
            extensions: nil,
            formatDescriptionOut: &fmt)
        guard st == noErr, let fmt else {
            lock.unlock()
            Diag.log("OXP formatDescription 失败 \(st)")
            return
        }
        srcWidth = w
        srcHeight = h

        let box = OutputBox()
        box.handler = { [weak self] buffer in self?.handleDecoded(buffer) }
        let ctx = Unmanaged.passRetained(box).toOpaque()
        outputBoxCtx = ctx

        var cbRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { decompressionOutputRefCon, _, _, _, imageBuffer, _, _ in
                let box = Unmanaged<OutputBox>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
                box.handler?(imageBuffer)
            },
            decompressionOutputRefCon: ctx)
        var sessionOut: VTDecompressionSession?
        let st2 = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmt,
            decoderSpecifications: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true],
            imageBufferAttributes: nil,
            outputCallback: &cbRecord,
            decompressionSessionOut: &sessionOut)
        guard st2 == noErr, let sessionOut else {
            Unmanaged<OutputBox>.fromOpaque(ctx).release()
            outputBoxCtx = nil
            lock.unlock()
            Diag.log("OXP 解码会话创建失败 \(st2)")
            return
        }
        formatDesc = fmt
        decoderSession = sessionOut
        receivedFirstFrame = false
        lock.unlock()
        report("视频格式已收到 \(w)×\(h)，等首帧…")
        Diag.log("OXP 解码器就绪 \(w)×\(h) fpsHint=\(fpsHint) avcC=\(avcC.count)B")
        sendText(["type": "keyframe", "screen": 0])
    }

    // MARK: - 二进制视频帧

    private func handleBinary(_ data: Data) {
        guard data.count > 24 else { return }
        let kind = data[data.startIndex]
        guard kind == 1 else { return }               // 1=Video，其他忽略
        let flags = data[data.startIndex + 2]
        let isKey = (flags & 0x01) != 0
        let ptsUs = Self.readI64LE(data, offset: 8)
        let payload = data.subdata(in: (data.startIndex + 24)..<data.endIndex)  // AVCC 整帧

        lock.lock()
        guard let fmt = formatDesc, let session = decoderSession else {
            lock.unlock()
            return
        }
        guard let sample = Self.makeSampleBuffer(avcc: payload, ptsUs: ptsUs, fmt: fmt) else {
            lock.unlock()
            return
        }
        var flagsOut = VTDecodeFrameFlags()
        let st = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: VTDecodeFrameFlags.enableAsynchronousDecompression,
            infoFlagsOut: &flagsOut)
        lock.unlock()
        if st != noErr {
            Diag.log("OXP 解码失败 \(st) key=\(isKey) size=\(payload.count)")
        }
    }

    private func handleDecoded(_ src: CVPixelBuffer) {
        guard running else { return }
        autoreleasepool {
            lock.lock()
            defer { lock.unlock() }
            let dest: CVPixelBuffer
            if destBuffers.count < 5 {
                guard let fresh = FrameRenderer.makeBuffer(width: width, height: height) else { return }
                destBuffers.append(fresh)
                dest = fresh
            } else {
                destIndex = (destIndex + 1) % destBuffers.count
                dest = destBuffers[destIndex]
            }
            var ci = CIImage(cvPixelBuffer: src)
            switch rotation {
            case 90: ci = ci.oriented(.right)
            case 180: ci = ci.oriented(.down)
            case 270: ci = ci.oriented(.left)
            default: break
            }
            ci = FrameRenderer.aspectFillTransform(ci, destWidth: width, destHeight: height)
            ciContext.render(ci, to: dest,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            latestBuffer = dest
            if !receivedFirstFrame {
                receivedFirstFrame = true
                decodedCount = 0
                report("CarPlay 首帧已解码，开始投屏")
                Diag.log("OXP 首帧已渲染 → \(width)x\(height) rot=\(rotation)")
            }
            decodedCount += 1
        }
    }

    // MARK: - 解码器清理

    /// 需已持有 lock
    private func teardownDecoderLocked() {
        if let session = decoderSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decoderSession = nil
        if let ctx = outputBoxCtx {
            Unmanaged<OutputBox>.fromOpaque(ctx).release()
        }
        outputBoxCtx = nil
        formatDesc = nil
        receivedFirstFrame = false
    }

    // MARK: - 工具

    private final class OutputBox {
        var handler: ((CVPixelBuffer) -> Void)?
    }

    /// 解析 avcC box 取 SPS/PPS（结构：version/profile/compat/level,
    /// lengthSizeMinusOne, numSPS, spsLen, SPS, numPPS, ppsLen, PPS）
    static func parseAvcC(_ data: Data) -> (Data, Data)? {
        let b = [UInt8](data)
        guard b.count >= 7 else { return nil }
        guard (b[4] & 0x03) == 3 else { return nil }      // lengthSizeMinusOne == 3（4 字节）
        var offset = 5
        let numSPS = Int(b[5] & 0x1F)
        guard numSPS >= 1 else { return nil }
        offset = 6
        var sps: Data? = nil
        for _ in 0..<numSPS {
            guard offset + 2 <= b.count else { return nil }
            let len = Int(b[offset]) << 8 | Int(b[offset + 1])
            offset += 2
            guard offset + len <= b.count else { return nil }
            if sps == nil { sps = Data(b[offset..<(offset + len)]) }
            offset += len
        }
        guard let sps, offset < b.count else { return nil }
        let numPPS = Int(b[offset] & 0x1F)
        offset += 1
        var pps: Data? = nil
        for _ in 0..<numPPS {
            guard offset + 2 <= b.count else { return nil }
            let len = Int(b[offset]) << 8 | Int(b[offset + 1])
            offset += 2
            guard offset + len <= b.count else { return nil }
            if pps == nil { pps = Data(b[offset..<(offset + len)]) }
            offset += len
        }
        guard let pps else { return nil }
        return (sps, pps)
    }

    /// AVCC payload → CMSampleBuffer（PTS 微秒）
    static func makeSampleBuffer(avcc: Data, ptsUs: Int64, fmt: CMVideoFormatDescription) -> CMSampleBuffer? {
        let total = avcc.count
        var blockBuffer: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: total, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: total,
            flags: 0, blockBufferOut: &blockBuffer)
        guard st == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        st = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer!,
                offsetIntoDestination: 0, dataLength: total)
        }
        guard st == kCMBlockBufferNoErr else { return nil }
        var sampleSize = total
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            decodeTimeStamp: CMTime.invalid)
        var sample: CMSampleBuffer?
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: fmt, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard st == noErr else { return nil }
        return sample
    }

    private static func readI64LE(_ data: Data, offset: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<8 {
            v |= Int64(data[data.startIndex + offset + i]) << (8 * i)
        }
        return v
    }
}
