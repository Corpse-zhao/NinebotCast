import Foundation

/// 标准 RTP (RFC 3550) + H.264 FU-A 分片 (RFC 6184)。
/// 注意：payload type / 时钟 / SSRC 等字段需要在拿到仪表真实抓包后核对，
/// 当前按最通用的 96 / 90kHz 处理。
struct RTPPacker {
    let payloadType: UInt8
    let ssrc: UInt32
    var maxPayloadSize: Int = 1200

    private(set) var sequence: UInt16 = 0
    private(set) var timestamp: UInt32 = 0

    init(payloadType: UInt8 = 96, ssrc: UInt32 = 0x4E424354 /* "NBCT" */) {
        self.payloadType = payloadType
        self.ssrc = ssrc
    }

    /// 每个 packetizeFrame 调用内部推进一次时间戳（90kHz 时钟）。
    mutating func packetizeFrame(nalus: [Data], fps: Int32) -> [Data] {
        timestamp &+= UInt32(90_000 / max(1, Int(fps)))
        var packets: [Data] = []
        for (index, nalu) in nalus.enumerated() {
            let marker = (index == nalus.count - 1)
            packets.append(contentsOf: packetizeNalu(nalu, timestamp: timestamp, marker: marker))
        }
        return packets
    }

    private mutating func makeHeader(marker: Bool, timestamp ts: UInt32) -> Data {
        sequence &+= 1
        var h = Data(capacity: 12)
        h.append(0x80) // V=2, P=0, X=0, CC=0
        h.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
        h.append(UInt8(sequence >> 8))
        h.append(UInt8(sequence & 0xFF))
        for shift in [24, 16, 8, 0] {
            h.append(UInt8((ts >> UInt32(shift)) & 0xFF))
        }
        for shift in [24, 16, 8, 0] {
            h.append(UInt8((ssrc >> UInt32(shift)) & 0xFF))
        }
        return h
    }

    private mutating func packetizeNalu(_ nalu: Data, timestamp ts: UInt32, marker: Bool) -> [Data] {
        let bytes = [UInt8](nalu)
        guard !bytes.isEmpty else { return [] }

        // 单包放得下：Single NAL Unit Mode
        if bytes.count <= maxPayloadSize {
            var packet = makeHeader(marker: marker, timestamp: ts)
            packet.append(contentsOf: bytes)
            return [packet]
        }

        // FU-A 分片
        let nalHeader = bytes[0]
        let nalType = nalHeader & 0x1F
        let nalNri = nalHeader & 0x60
        let fuIndicator = nalNri | 28 // FU-A
        let payload = Array(bytes[1...])

        var packets: [Data] = []
        var offset = 0
        while offset < payload.count {
            let chunkLen = min(maxPayloadSize - 2, payload.count - offset)
            let isFirst = offset == 0
            let isLast = offset + chunkLen >= payload.count
            var fuHeader = UInt8(nalType)
            if isFirst { fuHeader |= 0x80 }
            if isLast { fuHeader |= 0x40 }

            var packet = makeHeader(marker: isLast ? marker : false, timestamp: ts)
            packet.append(fuIndicator)
            packet.append(fuHeader)
            packet.append(contentsOf: payload[offset..<offset + chunkLen])
            packets.append(packet)
            offset += chunkLen
        }
        return packets
    }
}

/// 把 Annex-B（00 00 00 01 起始码）流拆成 NALU 列表
enum AnnexB {
    static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var nalus: [Data] = []
        var start: Int? = nil
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if let s = start, i > s {
                    nalus.append(Data(bytes[s..<i]))
                }
                start = i + 3
                i += 3
            } else if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0
                        && i + 3 < bytes.count && bytes[i + 3] == 1 {
                if let s = start, i > s {
                    nalus.append(Data(bytes[s..<i]))
                }
                start = i + 4
                i += 4
            } else {
                i += 1
            }
        }
        if let s = start, bytes.count > s {
            nalus.append(Data(bytes[s...]))
        }
        return nalus.filter { !$0.isEmpty }
    }
}
