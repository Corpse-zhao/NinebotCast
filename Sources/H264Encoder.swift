import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox

/// VideoToolbox H.264 硬编码器，输出 Annex-B 流（关键帧前自带 SPS/PPS）
final class H264Encoder {
    /// (annexB 数据, 是否关键帧)
    var onAnnexBFrame: ((Data, Bool) -> Void)?

    private var session: VTCompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: Data?
    private let callbackQueue = DispatchQueue(label: "ninebotcast.vt")

    func setup(width: Int, height: Int, fps: Int32, bitrate: UInt32) -> Bool {
        teardown()

        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_PreferHardwareAcceleratedVideoEncoder: true
        ]

        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer else { return }
                guard let refcon else { return }
                let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
                encoder.handleOutput(sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionQueue: callbackQueue,
            compressionSessionOut: &sessionOut)

        guard status == noErr, let session = sessionOut else {
            NSLog("VTCompressionSessionCreate failed: \(status)")
            return false
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: Int(fps)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: Int(fps * 2)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)

        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            NSLog("VTCompressionSessionPrepareToEncodeFrames failed")
            return false
        }
        self.session = session
        return true
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimestamp: presentationTime,
            duration: CMTime.invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil)
    }

    func teardown() {
        if let session {
            VTCompressionSessionEndCompressionSession(session)
        }
        session = nil
        formatDescription = nil
        parameterSets = nil
    }

    deinit {
        teardown()
    }

    private func handleOutput(sampleBuffer: CMSampleBuffer) {
        if let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
           desc !== formatDescription {
            formatDescription = desc
            parameterSets = Self.parameterSets(from: desc)
        }

        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyFrame = !notSync
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer)
        guard let pointer = dataPointer, totalLength > 0 else { return }

        var annexB = Data()
        if isKeyFrame, let ps = parameterSets {
            annexB.append(ps)
        }
        annexB.append(Self.avccToAnnexB(Data(bytes: UnsafeRawPointer(pointer), count: totalLength)))
        onAnnexBFrame?(annexB, isKeyFrame)
    }

    /// VT 输出为 AVCC（4 字节长度前缀），转成 Annex-B
    private static func avccToAnnexB(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data()
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: bytes[offset..<offset + length])
            offset += length
        }
        return out
    }

    private static func parameterSets(from desc: CMVideoFormatDescription) -> Data? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
                numberOfParameterSetsOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
                numberOfParameterSetsOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            let sps = spsPointer, let pps = ppsPointer
        else { return nil }

        var data = Data([0, 0, 0, 1])
        data.append(contentsOf: UnsafeBufferPointer(start: sps, count: spsSize))
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(contentsOf: UnsafeBufferPointer(start: pps, count: ppsSize))
        return data
    }
}
