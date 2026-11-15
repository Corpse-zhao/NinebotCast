import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// 摄像头源：AVCaptureSession + VideoDataOutput，只保留最新一帧。
/// produceFrame 每个节拍取最新帧渲染成仪表尺寸，摄像头帧率低于投屏帧率时
/// 会重复上一帧，画面依然连续。
///
/// iOS 限制：App 退后台后摄像头会停止采集（系统行为，保活也救不了），
/// 此时画面停在最后一帧，但流不会断；图片/视频源不受此限制。
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ninebotcast.camera")
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var ciContext: CIContext?
    private var configured = false
    private(set) var active = false

    /// 启动采集；err 非 nil 表示失败原因（回调在 sessionQueue 上）
    func start(position: AVCaptureDevice.Position, completion: ((String?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let err = self.configure(position: position)
            completion?(err)
        }
    }

    private func configure(position: AVCaptureDevice.Position) -> String? {
        guard !configured else { return nil }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position) else {
            return "没有找到\(position == .front ? "前置" : "后置")摄像头"
        }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return "摄像头输入创建失败（权限被拒也会走到这里）"
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else {
            return "摄像头输出创建失败"
        }
        session.addOutput(output)
        session.startRunning()
        configured = true
        active = true
        Diag.log("摄像头已启动 \(position == .front ? "前置" : "后置")")
        return nil
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latestBuffer = pb // 持有强引用，CoreVideo 会为池补新 buffer，内容不会被覆盖
        lock.unlock()
    }

    /// 取最新一帧并渲染成目标尺寸（含旋转与铺满）
    func renderedFrame(width: Int, height: Int, rotation: Int) -> CVPixelBuffer? {
        lock.lock()
        guard let raw = latestBuffer else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        if ciContext == nil { ciContext = CIContext(options: nil) }
        guard let ciContext else { return nil }
        guard let dest = FrameRenderer.makeBuffer(width: width, height: height) else { return nil }
        var ci = CIImage(cvPixelBuffer: raw)
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
        sessionQueue.async { [weak self] in
            guard let self, self.configured else { return }
            self.session.stopRunning()
            self.configured = false
            self.active = false
            self.lock.lock()
            self.latestBuffer = nil
            self.lock.unlock()
            Diag.log("摄像头已停止")
        }
    }
}
