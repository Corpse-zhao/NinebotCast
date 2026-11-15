import Foundation
import Darwin

/// 在仪表热点网段里扫出「谁在 5013 上听 RTCP」。
///
/// 这件事的意义不只是找 IP：
/// - 扫到有人回 pong → 说明仪表在监听、并且认这套 RTCP 方言，地址填错是之前失败的原因；
/// - 一个人都不回 → 说明仪表根本没进投屏接收态（或端口不同），
///   那问题不在画面、在「让仪表进入接收状态」这一步。
enum LanScanner {
    struct Hit {
        let ip: String
        let rttMs: Int
        let replyCount: Int
        let replyHex: String
    }

    /// 本机 Wi-Fi IPv4，例如 192.168.1.23
    static func localIPv4() -> String? {
        LocalAddress.primaryIPv4()
    }

    /// 由本机 IP 推前三段，例如 192.168.1
    static func localPrefix() -> String? {
        guard let ip = localIPv4() else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    /// 并发扫 1...254，逐个发 RTCP ping，收集回包。
    /// found 在找到第一个回应时回调（便于界面立刻回填 IP），completion 一定在主线程回调。
    static func scan(prefix: String,
                     port: UInt16 = 5013,
                     waitSeconds: Double = 2.0,
                     found: @escaping (Hit) -> Void,
                     completion: @escaping ([Hit]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var hits: [Hit] = []

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else {
                Diag.log("scan: socket() 失败")
                DispatchQueue.main.async { completion([]) }
                return
            }
            defer { close(fd) }

            setNonBlocking(fd)
            let boundPort = bindLocal(fd, preferredPort: port)
            Diag.log("scan: 本地绑定端口 \(boundPort)")

            let payload = RTCP.ping(counter: 1)
            var sentAt: [String: Int] = [:]
            for i in 1...254 {
                let ip = "\(prefix).\(i)"
                if sendTo(fd, ip: ip, port: port, payload: payload) {
                    sentAt[ip] = nowMs()
                }
            }
            Diag.log("scan: 已向 \(prefix).1-254:\(port) 发出 \(sentAt.count) 个 ping")

            let deadline = Date().addingTimeInterval(waitSeconds)
            var buffer = [UInt8](repeating: 0, count: 2048)
            while Date() < deadline {
                if let (ip, bytes) = receiveFrom(fd, buffer: &buffer) {
                    if let index = hits.firstIndex(where: { $0.ip == ip }) {
                        let old = hits[index]
                        hits[index] = Hit(ip: ip,
                                          rttMs: old.rttMs,
                                          replyCount: old.replyCount + 1,
                                          replyHex: hex(bytes))
                    } else {
                        let rtt = max(0, nowMs() - (sentAt[ip] ?? nowMs()))
                        let hit = Hit(ip: ip, rttMs: rtt, replyCount: 1, replyHex: hex(bytes))
                        hits.append(hit)
                        Diag.log("scan: \(ip) 回应 \(bytes.count) 字节 \(hit.replyHex)")
                        DispatchQueue.main.async { found(hit) }
                    }
                } else {
                    usleep(15_000)
                }
            }

            Diag.log("scan: 完成，\(hits.count) 个主机回应")
            let result = hits
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - POSIX 细节

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// 先在 5013 上绑（和官方一致），失败了就退到临时端口，保证扫描总能跑
    private static func bindLocal(_ fd: Int32, preferredPort: UInt16) -> UInt16 {
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        for candidate in [preferredPort, UInt16(0)] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let ok = withUnsafePointer(to: &addr) { pointer -> Bool in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if ok {
                var actual = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let got = withUnsafeMutablePointer(to: &actual) { pointer -> Bool in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        getsockname(fd, sa, &length) == 0
                    }
                }
                return got ? UInt16(bigEndian: actual.sin_port) : candidate
            }
        }
        return 0
    }

    private static func sendTo(_ fd: Int32, ip: String, port: UInt16, payload: Data) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
        let bytes = [UInt8](payload)
        let sent = withUnsafePointer(to: &addr) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, bytes, bytes.count, 0, sa,
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent > 0
    }

    private static func receiveFrom(_ fd: Int32, buffer: inout [UInt8]) -> (String, [UInt8])? {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = withUnsafeMutablePointer(to: &addr) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buffer, buffer.count, 0, sa, &length)
            }
        }
        guard received > 0 else { return nil }

        var raw = addr.sin_addr
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &raw, &host, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return (String(cString: host), Array(buffer[0..<received]))
    }
}
