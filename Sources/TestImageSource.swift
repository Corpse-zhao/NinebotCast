import UIKit
import CoreVideo

/// 测试图帧生成器：色条 + 移动滑块 + 帧计数文字，用于验证仪表能否出画面
enum TestImageSource {
    static func makeFrame(index: Int64, width: Int, height: Int) -> CVPixelBuffer? {
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

        // 黑底
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 色条（上半部）
        let colors: [UIColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue, .black]
        let barWidth = w / CGFloat(colors.count)
        for (i, color) in colors.enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: CGFloat(i) * barWidth, y: h * 0.45, width: barWidth, height: h * 0.2))
        }

        // 移动滑块（证明画面在动）
        let sliderX = CGFloat(Int(index) % Int(max(1, Int(w) - 80)))
        context.setFillColor(UIColor.systemGreen.cgColor)
        context.fill(CGRect(x: sliderX, y: h * 0.72, width: 80, height: h * 0.12))

        // 帧计数
        let text = "NINEBOT CAST  #\(index)"
        let attrs2: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: max(18, h * 0.09)),
            .foregroundColor: UIColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs2)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 16, y: h - h * 0.18)
        CTLineDraw(line, context)

        return pixelBuffer
    }
}
