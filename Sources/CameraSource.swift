import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// 摄像头源：AVCaptureSession + VideoDataOutput，只保留最新一帧。
/// produceFrame 每个节拍取最新帧渲染成仪表尺寸，摄像头帧率低于投屏帧率时
/// 会重复上一帧，画面依然连续。
///
/// 权限：先走 AVCaptureDevice.requestAccess，拒绝时给出可操作的提示，
/// 不再直接动 session（v0.13 一点就闪退，多半是没请求权限就配置 session）。
/// 每一步都打诊断日志，万一还有问题，日志能定位到具体哪一步。
///
/// iOS 限制：App 退后台后摄像头会停止采集（系统行为，保活救不了），
/// 此时画面停在最后一帧，但流不会断；图片/视频源不受此限制。
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ninebotcast.camera")
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var ciContext: CIContext?
    private var configured = false
    private(set) var active = false

    /// 启动采集；err 非 nil 表示失败原因
    func start(position: AVCaptureDevice.Position, completion: ((String?) -> Void)? = nil) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let err = self.configure(position: position)
                completion?(err)
            }
        case .notDetermined:
            Diag.log("camera: 首次使用，请求相机权限")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.start(position: position, completion: completion)
                } else {
                    Diag.log("camera: 相机权限被拒绝")
                    completion?("相机权限被拒绝：去 设置 > 隐私与安全性 > 相机 里打开")
                }
            }
        case .denied, .restricted:
            Diag.log("camera: 相机权限被拒绝/受限")
            completion?("相机权限被拒绝：去 设置 > 隐私与安全性 > 相机 里打开")
        @unknown default:
            completion?("相机权限状态未知")
        }
    }

    private func configure(position: AVCaptureDevice.Position) -> String? {
        Diag.log("camera: 开始配置（\(position == .front ? "前置" : "后置")）")
        guard !configured else { return nil }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position) else {
            Diag.log("camera: 找不到摄像头设备")
            return "没有找到\(position == .front ? "前置" : "后置")摄像头"
        }
        Diag.log("camera: 设备 OK \(device.localizedName)")
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                Diag.log("camera: canAddInput false")
                return "摄像头输入添加失败"
            }
            session.addInput(input)
        } catch {
            Diag.log("camera: 输入创建异常 \(error.localizedDescription)")
            return "摄像头输入创建失败：\(error.localizedDescription)"
        }
        Diag.log("camera: 输入 OK")

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else {
            Diag.log("camera: canAddOutput false")
            return "摄像头输出添加失败"
        }
        session.addOutput(output)
        Diag.log("camera: 输出 OK，启动 session")
        session.startRunning()
        configured = true
        active = true
        Diag.log("camera: 已启动，开始出帧")
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
            Diag.log("camera: 已停止")
        }
    }
}
