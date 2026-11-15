import AVFoundation
import CoreImage
import CoreVideo

/// 相册视频源：AVAssetReader 逐帧解码（BGRA），画成仪表尺寸后循环播放。
/// 取帧是同步的：produceFrame 每个节拍拉一帧，所以视频按投屏帧率播放，
/// 30fps 的视频以 20fps 投时播放速度会慢 1.5 倍，属于预期行为。
final class VideoFrameSource {
    private let url: URL
    private let width: Int
    private let height: Int
    private let rotation: Int
    private let ciContext: CIContext
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private(set) var failed = false

    init(url: URL, width: Int, height: Int, rotation: Int) {
        self.url = url
        self.width = width
        self.height = height
        self.rotation = rotation
        self.ciContext = CIContext(options: nil)
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        openReader()
    }

    /// 调用方需已持有 lock
    private func openReader() {
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
        trackOutput.alwaysCopiesSampleBuffer = false
        newReader.add(trackOutput)
        guard newReader.startReading() else {
            Diag.log("视频源：startReading 失败 \(String(describing: newReader.error))")
            failed = true
            return
        }
        self.reader = newReader
        self.output = trackOutput
        let size = track.naturalSize
        Diag.log("视频源已打开 \(Int(size.width))x\(Int(size.height)) rot=\(rotation)")
    }

    /// 取下一帧并渲染成目标尺寸；播完一轮自动循环重开
    func nextFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if reader == nil || output == nil {
            if failed { return nil }
            openReader()
        }
        if let sample = pullSample() {
            return render(sample)
        }
        // 到末尾了：重开一轮再取
        reader?.cancelReading()
        reader = nil
        output = nil
        if failed { return nil }
        openReader()
        if let sample = pullSample() {
            return render(sample)
        }
        return nil
    }

    /// 调用方需已持有 lock
    private func pullSample() -> CMSampleBuffer? {
        guard let output, let reader, reader.status == .reading else { return nil }
        return output.copyNextSampleBuffer()
    }

    private func render(_ sample: CMSampleBuffer) -> CVPixelBuffer? {
        guard let src = CMSampleBufferGetImageBuffer(sample) else { return nil }
        guard let dest = FrameRenderer.makeBuffer(width: width, height: height) else { return nil }
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
        return dest
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        reader?.cancelReading()
        reader = nil
        output = nil
    }
}
