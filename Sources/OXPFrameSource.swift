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
    private let fpsHint: Int

    private let lock = NSLock()              // 保护 latestBuffer / 解码器 / 会话
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var formatDesc: CMVideoFormatDescription?
    private var installedAvcC: Data?
    private var decoderSession: VTDecompressionSession?
    private var outputCtx: UnsafeMutableRawPointer?

    private var destBuffers: [CVPixelBuffer] = []
    private var destIndex = 0
    private var latestBuffer: CVPixelBuffer?
    private let ciContext = CIContext(options: nil)

    private(set) var running = false
    private var reconnectAttempt = 0
    private var reconnectTimer: DispatchSourceTimer?
    private var keyframeTimer: DispatchSourceTimer?
    private var fallbackTimer: DispatchSourceTimer?
    private var srcWidth = 0
    private var srcHeight = 0
    private var receivedFirstFrame = false
    private var decodedCount = 0

    /// 线协议：OXP（/oxp/v0，24 字节头）或 CarWithin（/stream，9 字节头）。
    /// 接收端可能是 OpenXPlay、CarWithin 等，端口都是 9888 —— 自动探测：奇数次尝试
    /// 走 OXP、偶数次走 CarWithin，谁先给出视频格式就锁谁，断线重连也优先用锁定的协议。
    private enum WireMode { case oxp, carwithin }
    private var lockedMode: WireMode?
    private var wireMode: WireMode = .oxp
    private var attemptCounter = 0

    private var pingTimer: DispatchSourceTimer?
    private var lastKeyRequest: TimeInterval = 0
    private var displaySent = false
    private var codecNudges = 0
    /// CarWithin 用 viewer 标识这条接收会话，重连要沿用同一个
    private var viewerID: String = {
        let key = "nbc.viewerID"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }()

    init(host: String, port: Int, width: Int, height: Int, rotation: Int, fps: Int = 30) {
        self.host = host
        self.port = port
        self.width = width
        self.height = height
        self.rotation = rotation
        self.fpsHint = fps
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
        fallbackTimer?.cancel(); fallbackTimer = nil
        pingTimer?.cancel(); pingTimer = nil
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
        attemptCounter += 1
        lock.lock()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        // 握手成功过的协议优先；否则自动探测轮换（先 OXP 后 CarWithin）
        let mode: WireMode
        if let m = lockedMode {
            mode = m
        } else if attemptCounter == 1 {
            // 上次成功过哪种协议就先试哪种，省掉一轮无用的探测
            mode = UserDefaults.standard.string(forKey: "nbc.wireMode") == "carwithin" ? .carwithin : .oxp
        } else {
            mode = attemptCounter % 2 == 1 ? .oxp : .carwithin
        }
        wireMode = mode
        let path = mode == .oxp ? "/oxp/v0" : "/stream"
        let url = URL(string: "ws://\(host):\(port)\(path)")!
        let t = s.webSocketTask(with: url)
        session = s
        task = t
        lock.unlock()
        let name = mode == .oxp ? "OXP" : "CarWithin"
        report("正在连接接收端（\(name) 协议）\(host):\(port)…")
        Diag.log("OXP 源连接 ws://\(host):\(port)\(path)（\(name)）")
        t.resume()
        receiveLoop()
    }

    private func scheduleReconnect(_ why: String) {
        guard running else { return }
        pingTimer?.cancel(); pingTimer = nil
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
        if wireMode == .oxp {
            sendHello()
            startKeyframeNag()
            startOxpFallback()
        } else {
            // CarWithin：对齐官方接收页 boot() 的顺序 —— ready → display → audio，然后每秒 ping
            startCarWithinSession()
        }
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

    // MARK: - CarWithin 会话（对齐官方接收页 boot 顺序）

    /// 官方接收页顺序：ready(decoder/viewer/audioClock) → display(尺寸/h265) → audio(enabled)
    /// 之后每秒 ping（t0 微秒）。缺 display 时服务端不知道该按什么尺寸、什么编码出流。
    private func startCarWithinSession() {
        displaySent = false
        codecNudges = 0
        sendCarWithin([
            "type": "ready",
            "decoder": "webcodecs",
            "viewer": viewerID,
            "audioClock": false
        ])
        sendCarWithinDisplay()
        sendCarWithin(["type": "audio", "enabled": false])
        startPing()
        report("已连接，等待 CarPlay 画面…")
        Diag.log("CarWithin ready → viewer=\(viewerID.prefix(8)) \(width)x\(height)@\(fpsHint)")
    }

    /// 告诉 CarWithin 接收端的分辨率与能力：h265 必须明确 false，否则可能下发 H.265
    private func sendCarWithinDisplay() {
        let dpr = 1
        sendCarWithin([
            "type": "display",
            "w": width * dpr,
            "h": height * dpr,
            "dpr": dpr,
            "sw": width * dpr,
            "sh": height * dpr,
            "hz": fpsHint,
            "h265": false,
            "fullscreen": true,
            "ua": "NinebotCast/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-") (iOS)"
        ])
        displaySent = true
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.running, self.wireMode == .carwithin else { return }
            let nowUs = Int64(Date().timeIntervalSince1970 * 1_000_000)
            self.sendCarWithin(["type": "ping", "t0": nowUs])
        }
        timer.resume()
        pingTimer = timer
    }

    /// 要关键帧：官方接收页限制 1 秒 1 次（一个 IDR 约等于 10 个普通帧）
    private func askKeyframe(_ reason: String) {
        let now = Date().timeIntervalSince1970
        guard now - lastKeyRequest >= 1.0 else { return }
        lastKeyRequest = now
        if wireMode == .carwithin {
            sendCarWithin(["type": "keyframe", "reason": reason])
        } else {
            sendText(["type": "keyframe", "screen": 0])
        }
    }

    /// OXP：服务端按二进制帧解析 JSON，沿用 .data
    private func sendText(_ json: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        task?.send(.data(data)) { _ in }
    }

    /// CarWithin：接收页用 `typeof e.data === 'string'` 区分控制消息和视频包，
    /// 发成二进制会被当成 H.264 帧直接丢掉，所以控制 JSON 必须走文本帧。
    private func sendCarWithin(_ json: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
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
        case "format":
            // CarWithin 真正的视频参数在这里（不是 hello）：
            // {page, decoder, codec, description=base64 avcC, width, height, fps, name}
            handleCarWithinFormat(obj)
        case "hello":
            // CarWithin 的 hello 只带页面版本/性能档/是否提供声音，不含编码参数
            Diag.log("CarWithin hello page=\(obj["page"] ?? "-") audio=\(obj["audio"] ?? "-")")
        case "ping":
            // 服务端 ping → 回 pong（带它给的 t0Us + 本地 t1/t2 微秒）
            let nowUs = Int64(Date().timeIntervalSince1970 * 1_000_000)
            let t0 = obj["t0Us"] as? Int64 ?? 0
            sendText(["type": "pong", "t0Us": t0, "t1Us": nowUs, "t2Us": nowUs])
        case "pong":
            // CarWithin：{type:pong, t0, s}，只用它做时钟对账，不必回
            break
        case "pause":
            Diag.log("OXP pause=\(obj["paused"] ?? "-")")
        default:
            Diag.log("OXP 消息 type=\(type)")
        }
    }

    /// OXP 模式下 4 秒还没拿到视频格式：多半是连到了不支持 OXP 的服务（比如
    /// CarWithin 只开了浏览器共享），换下一种协议重连
    private func startOxpFallback() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 4)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.lock.lock()
            let got = self.formatDesc != nil
            self.lock.unlock()
            if !got {
                Diag.log("OXP 路径 4 秒无视频格式，切换 CarWithin 协议重试")
                self.lockedMode = nil
                self.attemptCounter += 1   // 下次 connect 走另一条协议
                self.task?.cancel(with: .goingAway, reason: nil)
            }
        }
        timer.resume()
        fallbackTimer?.cancel()
        fallbackTimer = timer
    }

    private func cancelFallback() {
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    private func handleCarWithinFormat(_ obj: [String: Any]) {
        let codec = obj["codec"] as? String ?? "avc1"
        let w = Self.intOf(obj, "width")
        let h = Self.intOf(obj, "height")
        let fps = Self.intOf(obj, "fps")
        let name = obj["name"] as? String ?? codec
        // CarWithin 只有 H.265 没被明确拒绝时才下发 hvc1；我们的解码链路是 H.264
        if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") {
            Diag.log("CarWithin 下发了 H.265（\(codec)），当前无法解码")
            report("接收端在用 H.265，本 App 只支持 H.264 —— 请在 CarWithin 的画面设置里改成 H.264")
            if codecNudges < 2 {
                codecNudges += 1
                sendCarWithinDisplay()      // 再明确一次 h265=false，逼服务端转 H.264
            }
            return
        }
        guard let descB64 = obj["description"] as? String,
              let avcC = Data(base64Encoded: descB64) else {
            Diag.log("CarWithin format 缺 description（codec=\(codec)）")
            askKeyframe("no-format")
            return
        }
        Diag.log("CarWithin format \(name) \(w)x\(h) \(fps)fps avcC=\(avcC.count)B")
        installDecoder(avcC: avcC, w: w, h: h, tag: "CarWithin")
    }

    private func handleVideoFormat(_ obj: [String: Any]) {
        guard let format = obj["format"] as? [String: Any],
              let configB64 = format["config"] as? String,
              let avcC = Data(base64Encoded: configB64) else {
            Diag.log("OXP video-format 缺 config")
            return
        }
        let w = Self.intOf(format, "width")
        let h = Self.intOf(format, "height")
        installDecoder(avcC: avcC, w: w, h: h, tag: "OXP")
        sendText(["type": "keyframe", "screen": 0])   // OXP 支持主动要 I 帧
    }

    /// 建解码器（OXP 与 CarWithin 两条协议共用；需已持有 lock 之前先拿锁）
    private func installDecoder(avcC: Data, w: Int, h: Int, tag: String) {
        lock.lock()
        // 服务端重复下发同样的 format 时不要重建解码器（会打断正在解的画面）
        if let prev = installedAvcC, prev == avcC, srcWidth == w, srcHeight == h, decoderSession != nil {
            lock.unlock()
            return
        }
        teardownDecoderLocked()
        guard let (sps, pps) = Self.parseAvcC(avcC) else {
            lock.unlock()
            Diag.log("\(tag) avcC 解析失败 \(avcC.count) 字节")
            return
        }
        // CMVideoFormatDescriptionCreateFromH264ParameterSets 需要稳定的指针数组：
        // 把 SPS/PPS 定住为 CFData，再取字节指针
        let cfDatas: [CFData] = [sps, pps].map { d in
            d.withUnsafeBytes { raw in
                CFDataCreate(nil, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count)
            }
        }
        var ptrs: [UnsafePointer<UInt8>] = cfDatas.map { UnsafePointer<UInt8>(CFDataGetBytePtr($0)!) }
        var sizes: [Int] = cfDatas.map { CFDataGetLength($0) }
        var fmt: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: &ptrs,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &fmt)
        guard st == noErr, let fmt else {
            lock.unlock()
            Diag.log("OXP formatDescription 失败 \(st)")
            return
        }
        srcWidth = w
        srcHeight = h

        // 经典 C 回调（completionHandler 变体要 iOS 17，设备是 16.x 用不了）
        let box = DecodeBox()
        box.handler = { [weak self] buffer in self?.handleDecoded(buffer) }
        let ctx = Unmanaged.passRetained(box).toOpaque()
        outputCtx = ctx

        var cbRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, _, _, imageBuffer, _, _ in
                if let imageBuffer, let refcon {
                    let box = Unmanaged<DecodeBox>.fromOpaque(refcon).takeUnretainedValue()
                    box.handler?(imageBuffer)
                }
            },
            decompressionOutputRefCon: ctx)
        var sessionOut: VTDecompressionSession?
        // 不强制指定硬解 key（该常量 iOS 17 才有）：系统默认优先硬解
        let st2 = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmt,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &cbRecord,
            decompressionSessionOut: &sessionOut)
        guard st2 == noErr, let sessionOut else {
            Unmanaged<DecodeBox>.fromOpaque(ctx).release()
            outputCtx = nil
            lock.unlock()
            Diag.log("\(tag) 解码会话创建失败 \(st2)")
            return
        }
        formatDesc = fmt
        decoderSession = sessionOut
        installedAvcC = avcC
        receivedFirstFrame = false
        lockedMode = wireMode      // 握手成功，锁定这条协议
        UserDefaults.standard.set(wireMode == .carwithin ? "carwithin" : "oxp", forKey: "nbc.wireMode")
        cancelFallback()
        lock.unlock()
        if wireMode == .carwithin { askKeyframe("decoder-ready") }
        report("\(tag) 视频格式已收到 \(w)×\(h)，等首帧…")
        Diag.log("\(tag) 解码器就绪 \(w)×\(h) avcC=\(avcC.count)B（协议锁定）")
    }

    // MARK: - 二进制视频帧

    private func handleBinary(_ data: Data) {
        let ptsUs: Int64
        let isKey: Bool
        let payload: Data
        if wireMode == .carwithin {
            // CarWithin：[0]=关键帧标志(1=key，3=音频包)，[1..8]=大端 64 位微秒时间戳，[9:]=AVCC
            guard data.count > 9 else { return }
            let flag = data[data.startIndex]
            if flag == 3 { return }                     // 音频包（我们没开声音）
            isKey = flag == 1
            ptsUs = Self.readBE64(data, offset: 1)
            payload = data.subdata(in: (data.startIndex + 9)..<data.endIndex)
        } else {
            // OXP：24 字节头（[0]=kind, [2]=flags, [8..15]=ptsUs 小端）
            guard data.count > 24 else { return }
            let kind = data[data.startIndex]
            guard kind == 1 else { return }            // 1=Video，其他忽略
            let flags = data[data.startIndex + 2]
            isKey = (flags & 0x01) != 0
            ptsUs = Self.readI64LE(data, offset: 8)
            payload = data.subdata(in: (data.startIndex + 24)..<data.endIndex)
        }

        lock.lock()
        guard let fmt = formatDesc, let session = decoderSession else {
            lock.unlock()
            return
        }
        guard let sample = Self.makeSampleBuffer(avcc: payload, ptsUs: ptsUs, fmt: fmt) else {
            lock.unlock()
            return
        }
        var infoFlags = VTDecodeInfoFlags()
        // 该变体 iOS 9+ 就有（completionHandler 版要 iOS 17，设备是 16.x）
        let st = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: ._EnableAsynchronousDecompression,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags)
        lock.unlock()
        if st != noErr {
            Diag.log("解码失败 \(st) key=\(isKey) size=\(payload.count)")
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
        if let ctx = outputCtx {
            Unmanaged<DecodeBox>.fromOpaque(ctx).release()
        }
        outputCtx = nil
        formatDesc = nil
        installedAvcC = nil
        receivedFirstFrame = false
    }

    // MARK: - 工具

    /// VT 解码回调的上下文（闭包不能直接进 refcon，套一层）
    private final class DecodeBox {
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
                with: raw.baseAddress!, blockBuffer: blockBuffer,
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

    /// JSON 数字可能是 Int / Double / NSNumber / 字符串，统一取整
    static func intOf(_ obj: [String: Any], _ key: String) -> Int {
        if let i = obj[key] as? Int { return i }
        if let d = obj[key] as? Double { return Int(d) }
        if let n = obj[key] as? NSNumber { return n.intValue }
        if let s = obj[key] as? String { return Int(s) ?? 0 }
        return 0
    }

    private static func readI64LE(_ data: Data, offset: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<8 {
            v |= Int64(data[data.startIndex + offset + i]) << (8 * i)
        }
        return v
    }

    private static func readBE64(_ data: Data, offset: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<8 {
            v = (v << 8) | Int64(data[data.startIndex + offset + i])
        }
        return v
    }
}
