import UIKit
import CoreVideo
import CoreGraphics

/// 把相册里选的一张图，画成仪表预设尺寸的 CVPixelBuffer（等比缩放居中、两侧补黑）。
/// 之后每帧都复用这块 buffer，只是反复编码发送——静态画面也能持续出帧。
enum PhotoSource {
    static func makePixelBuffer(from image: UIImage, width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 16, height > 16 else { return nil }

        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
            let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        guard let cgImage = image.cgImage else { return nil }
        let imageW = CGFloat(cgImage.width), imageH = CGFloat(cgImage.height)
        guard imageW > 0, imageH > 0 else { return nil }
        let scale = min(w / imageW, h / imageH)
        let drawW = imageW * scale
        let drawH = imageH * scale
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(
            x: (w - drawW) / 2,
            y: (h - drawH) / 2,
            width: drawW,
            height: drawH))
        return pixelBuffer
    }
}
