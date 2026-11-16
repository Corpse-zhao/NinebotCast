import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// 相册视频源 v2。
///
/// v0.13 的实现是在发送节拍里「同步解码 + 渲染 + 建新 buffer」，一帧超过 50ms
/// 就掉帧，实测非常卡。v2 改成：
/// - 独立解码线程按帧率持续解码「最新帧」，发送端只拿现成 buffer，互不阻塞；
/// - 3 块目标 buffer 轮换写入，避免编码器还在处理上一帧时内容被覆盖；
/// - 播完一轮自动循环重开。
final class VideoFrameSource {
    private let url: URL
    private let width: Int
    private let height: Int
    private let rotation: Int
    private let fps: Int
    private let ciContext: CIContext
    private let decodeQueue = DispatchQueue(label: "ninebotcast.videodecode")
    private var decodeTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var destBuffers: [CVPixelBuffer] = []
    private var destIndex = 0
    private var latestBuffer: CVPixelBuffer?
    private(set) var failed = false

    init(url: URL, width: Int, height: Int, rotation: Int, fps: Int) {
        self.url = url
        self.width = width
        self.height = height
        self.rotation = rotation
        self.fps = max(1, fps)
        self.ciContext = CIContext(options: nil)
    }

    func start() {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.reader == nil, !self.failed {
                self.openReaderLocked()
            }
            self.lock.unlock()
            guard !self.failed else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.decodeQueue)
            timer.schedule(deadline: .now(),
                           repeating: .milliseconds(1000 / self.fps))
            timer.setEventHandler { [weak self] in self?.decodeOnce() }
            timer.resume()
            self.decodeTimer = timer
        }
    }

    /// 解码线程调用
    private func decodeOnce() {
        lock.lock()
        defer { lock.unlock() }
        if reader == nil || output == nil {
            if failed { return }
            openReaderLocked()
            if reader == nil { return }
        }
        guard let sample = pullSampleLocked() else {
            // 播完一轮：重开 reader 实现循环
            reader?.cancelReading()
            reader = nil
            output = nil
            if !failed {
                openReaderLocked()
            }
            return
        }
        guard let dest = nextDestBufferLocked() else { return }
        renderLocked(sample, into: dest)
        latestBuffer = dest
    }

    /// 需已持有 lock
    private func openReaderLocked() {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            Diag.log("视频源：没有视频轨道 \(url.lastPathComponent)")
            failed = true
            return
        }
        guard let newReader = try? AVAssetReader(asset: asset) else {
            Diag.log("视频源：AVAssetReader 创建失败")
            failed = true
            return
        }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        trackOutput.alwaysCopiesSampleData = false
        newReader.add(trackOutput)
        guard newReader.startReading() else {
            Diag.log("视频源：startReading 失败 \(String(describing: newReader.error))")
            failed = true
            return
        }
        self.reader = newReader
        self.output = trackOutput
        let size = track.naturalSize
        Diag.log("视频源已打开 \(Int(size.width))x\(Int(size.height)) → \(width)x\(height) rot=\(rotation) @\(fps)fps")
    }

    /// 需已持有 lock
    private func pullSampleLocked() -> CMSampleBuffer? {
        guard let output, let reader, reader.status == .reading else { return nil }
        return output.copyNextSampleBuffer()
    }

    /// 需已持有 lock：3 块 buffer 轮换，降低分配开销也避免覆盖还在编码的帧
    private func nextDestBufferLocked() -> CVPixelBuffer? {
        if destBuffers.count < 3 {
            guard let buffer = FrameRenderer.makeBuffer(width: width, height: height) else {
                return nil
            }
            destBuffers.append(buffer)
            return buffer
        }
        destIndex = (destIndex + 1) % destBuffers.count
        return destBuffers[destIndex]
    }

    /// 需已持有 lock
    private func renderLocked(_ sample: CMSampleBuffer, into dest: CVPixelBuffer) {
        guard let src = CMSampleBufferGetImageBuffer(sample) else { return }
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
    }

    /// 发送线程调用：拿最新解码好的帧（可能重复取同一帧，编码器输出码率极低）
    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestBuffer
    }

    func stop() {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.decodeTimer?.cancel()
            self.decodeTimer = nil
            self.lock.lock()
            self.reader?.cancelReading()
            self.reader = nil
            self.output = nil
            self.latestBuffer = nil
            self.lock.unlock()
        }
    }
}
