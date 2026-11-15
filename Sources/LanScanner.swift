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
    /// 会跳过本机 IP（否则内核把包回环给自己，误报成"仪表回应"）。
    /// found 在找到第一个回应时回调（便于界面立刻回填 IP），completion 一定在主线程回调。
    static func scan(prefix: String,
                     port: UInt16 = 5013,
                     waitSeconds: Double = 2.0,
                     found: @escaping (Hit) -> Void,
                     completion: @escaping ([Hit]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var hits: [Hit] = []
            let selfIP = localIPv4()

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else {
                Diag.log("scan: socket() 失败")
                DispatchQueue.main.async { completion([]) }
                return
            }
            defer { close(fd) }

            setNonBlocking(fd)
            let boundPort = bindLocal(fd, preferredPort: port)
            Diag.log("scan: 本地绑定端口 \(boundPort)，本机 \(selfIP ?? "nil") 已排除")

            let payload = RTCP.ping(counter: 1)
            var sentAt: [String: Int] = [:]
            for i in 1...254 {
                let ip = "\(prefix).\(i)"
                if ip == selfIP { continue } // 自己 ping 自己只会收到回声
                if sendTo(fd, ip: ip, port: port, payload: payload) {
                    sentAt[ip] = nowMs()
                }
            }
            Diag.log("scan: 已向 \(prefix).1-254:\(port) 发出 \(sentAt.count) 个 ping（排除本机）")

            let deadline = Date().addingTimeInterval(waitSeconds)
            var buffer = [UInt8](repeating: 0, count: 2048)
            while Date() < deadline {
                if let (ip, bytes) = receiveFrom(fd, buffer: &buffer) {
                    if ip == selfIP { continue }
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

            Diag.log("scan: 完成，\(hits.count) 个主机回应（不含本机）")
            let result = hits
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// TCP 端口扫描：谁开着这个端口谁就大概率是仪表/车机
    /// （作者截图里仪表开着 https 8443）。非阻塞 connect + poll，分批避免撞 fd 上限。
    /// completion 在主线程回调，返回开放该端口的主机列表。
    static func tcpScan(prefix: String,
                        port: UInt16 = 8443,
                        waitMs: Int = 2500,
                        found: @escaping (String) -> Void,
                        completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let selfIP = localIPv4()
            var open: [String] = []
            let hosts = (1...254).map { "\(prefix).\($0)" }.filter { $0 != selfIP }
            let globalDeadline = Date().addingTimeInterval(Double(waitMs) / 1000.0)
            Diag.log("tcpScan: 开始 \(prefix).1-254:\(port)（排除本机 \(selfIP ?? "nil")）")

            var queue = hosts
            while !queue.isEmpty && Date() < globalDeadline {
                let chunk = Array(queue.prefix(60))
                queue.removeFirst(chunk.count)
                var pending: [(fd: Int32, ip: String)] = []

                for ip in chunk {
                    let fd = socket(AF_INET, SOCK_STREAM, 0)
                    guard fd >= 0 else { continue }
                    setNonBlocking(fd)
                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = port.bigEndian
                    guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
                        close(fd)
                        continue
                    }
                    let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    if result == 0 {
                        // 极少见：本地直接连上
                        open.append(ip)
                        Diag.log("tcpScan: \(ip):\(port) 可连接（立即）")
                        DispatchQueue.main.async { found(ip) }
                        close(fd)
                    } else if errno == EINPROGRESS {
                        pending.append((fd, ip))
                    } else {
                        close(fd)
                    }
                }

                // 等这一批出结果
                while !pending.isEmpty && Date() < globalDeadline {
                    var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                    let ready = poll(&fds, nfds_t(fds.count), 200)
                    guard ready > 0 else { continue }
                    var still: [(fd: Int32, ip: String)] = []
                    for (idx, entry) in pending.enumerated() {
                        let re = fds[idx].revents
                        if re & (Int16(POLLOUT) | Int16(POLLERR) | Int16(POLLHUP)) != 0 {
                            var err: Int32 = 0
                            var len = socklen_t(MemoryLayout<Int32>.size)
                            getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                            if err == 0 {
                                open.append(entry.ip)
                                Diag.log("tcpScan: \(entry.ip):\(port) 可连接")
                                DispatchQueue.main.async { found(entry.ip) }
                            }
                            close(entry.fd)
                        } else {
                            still.append(entry)
                        }
                    }
                    pending = still
                }
                for entry in pending { close(entry.fd) }
                pending = []
            }

            Diag.log("tcpScan: 完成，\(open.count) 个主机开着 \(port)")
            let result = open
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
