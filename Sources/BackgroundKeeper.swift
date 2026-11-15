import AVFoundation
import UIKit

/// 投屏期间的后台保活。
///
/// 用户实测：App 一退后台，投屏就断——因为 iOS 会在几秒内挂起后台进程，
/// 定时器全停，帧和心跳都没了。Info.plist 里早就声明了 UIBackgroundModes=audio，
/// 但声明不生效，必须真的跑一个音频会话。
///
/// 做法：AVAudioSession 设为 .playback，启动一个输出静音的 AVAudioEngine。
/// 引擎在跑，进程就不会被挂起，投屏定时器在后台继续走。
/// 同时投屏期间禁掉自动锁屏（锁屏等于退后台）。
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var running = false

    /// 是否已在保活（给界面提示用）
    var isActive: Bool { running }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
            guard let format else {
                Diag.log("后台保活：音频格式创建失败，退后台会断流")
                return
            }
            let src = AVAudioSourceNode(format: format) { _, _, _, audioBufferList -> OSStatus in
                // 输出全零 = 静音；目的只是让音频会话保持活跃
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in buffers {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                return noErr
            }
            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: format)
            try engine.start()
            sourceNode = src
            running = true
            Diag.log("后台保活启动（静音音频 + 禁止锁屏）")
        } catch {
            // 保活失败不致命：只是退后台会断流，前台照常
            Diag.log("后台保活启动失败 \(error.localizedDescription)")
        }
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard running else { return }
        running = false
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
        }
        sourceNode = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        Diag.log("后台保活停止")
    }
}
