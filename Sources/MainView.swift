import SwiftUI

enum AppVersion {
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
    static var display: String { "v\(short) (\(build))" }
}

struct MainView: View {
    @StateObject private var engine = CastEngine()
    @State private var presetIndex = 0
    @State private var host = "192.168.1.13"
    @State private var duplicateKeyframes = true
    @State private var pingOnly = false
    @State private var scanning = false
    @State private var tcpScanning = false
    @State private var scanSummary = ""
    @State private var diagText = Diag.tail(16)
    @State private var localIP = "-"

    var body: some View {
        NavigationStack {
            Form {
                // 版本横幅放最顶上，打开就能看到：装没装对包，一眼分辨
                Section {
                    HStack {
                        Text("v\(AppVersion.short) (\(AppVersion.build))")
                            .font(.title2)
                            .bold()
                            .monospacedDigit()
                        Spacer()
                        Text("显示 1.0 = 旧包（会闪退）")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("仪表预设") {
                    Picker("预设", selection: $presetIndex) {
                        ForEach(Array(DashboardPreset.all.enumerated()), id: \.element.id) { index, preset in
                            Text(preset.title).tag(index)
                        }
                    }
                    TextField("仪表 IP", text: $host)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    Text("本机 Wi-Fi 地址：\(localIP)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("先在仪表或官方 App 的巡航投屏里让仪表进入投屏状态（官方是点车辆页巡航入口）。iPhone 在 设置 > Wi-Fi 连上仪表热点后，把这里填成热点详情页里「路由器」那行的地址。别填本机地址。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("找不到 IP？扫一下") {
                    Button {
                        runScan()
                    } label: {
                        Label(scanning ? "RTCP 扫描中…（约 2 秒）" : "扫描：谁在 5013 回应 RTCP ping",
                              systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(scanning || tcpScanning)
                    Button {
                        runTcpScan()
                    } label: {
                        Label(tcpScanning ? "TCP 扫描中…（约 3 秒）" : "扫描：谁开着 8443 端口（找仪表）",
                              systemImage: "network")
                    }
                    .disabled(scanning || tcpScanning)
                    Button {
                        if let prefix = LanScanner.localPrefix() {
                            host = "\(prefix).1"
                            scanSummary = "已填入网关地址 \(host)，一般就是仪表"
                        }
                    } label: {
                        Label("填入网关地址 .1（仪表热点的网关通常就是仪表）",
                              systemImage: "arrow.uturn.right.circle")
                    }
                    if !scanSummary.isEmpty {
                        Text(scanSummary)
                            .font(.footnote)
                            .monospaced()
                    }
                    Text("提示：8443 扫到的 IP 大概率是仪表；RTCP 只在仪表处于接收态时才回应。填好后直接「开始投屏」，看帧数有没有涨、仪表有没有出画面。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("投屏（协议已对齐官方 APK）") {
                    Toggle("关键帧重发", isOn: $duplicateKeyframes)
                    Toggle("只发 ping（不编码，用于排查闪退）", isOn: $pingOnly)
                    Button {
                        engine.start(preset: DashboardPreset.all[presetIndex],
                                      host: host,
                                      duplicateKeyframes: duplicateKeyframes,
                                      pingOnly: pingOnly)
                    } label: {
                        Label(pingOnly ? "开始（仅 ping）" : "开始投屏（测试图）",
                              systemImage: "play.rectangle.fill")
                    }
                    .disabled(engine.isRunning)
                    Button(role: .destructive) {
                        engine.stop()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                }

                Section("状态") {
                    Text(engine.statusText)
                    Text("已发送 \(engine.sentFrames) 帧 / \(engine.sentPackets) 包")
                        .monospacedDigit()
                    Text(engine.rtcpPongCount > 0
                         ? "RTCP 回应 \(engine.rtcpPongCount) 次 · 往返 \(max(0, engine.lastRTTMs))ms"
                         : "RTCP 尚无回应（等 2 秒以上）")
                        .monospacedDigit()
                        .foregroundColor(engine.rtcpPongCount > 0 ? .green : .secondary)
                    if !engine.dashboardReport.isEmpty {
                        Text(engine.dashboardReport)
                            .font(.footnote)
                            .foregroundColor(.blue)
                    }
                }

                Section("诊断（上次运行到哪一步）") {
                    Text(diagText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    HStack {
                        Button("刷新") { diagText = Diag.tail(20) }
                        Spacer()
                        Button("清空", role: .destructive) {
                            Diag.reset()
                            diagText = Diag.tail(4)
                        }
                    }
                    .font(.footnote)
                }

                Section("协议要点（逆向自官方 APK）") {
                    Text("视频 RTP 20 字节扩展头 · PT 32 · 1380 字节分片")
                    Text("时间戳毫秒 · 每帧带 SPS/PPS · 关键帧每秒 1 个")
                    Text("RTCP ping/pong 每秒 1 次（20 字节）")
                    Text("本机端口绑定 5012/5013")
                }

                Section {
                    Text("版本 \(AppVersion.display)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Ninebot Cast")
            .onAppear {
                localIP = LanScanner.localIPv4() ?? "未连 Wi-Fi"
                diagText = Diag.tail(16)
                Diag.log("MainView 出现，版本 \(AppVersion.display)")
            }
        }
    }

    private func runScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        scanning = true
        scanSummary = "扫描 \(prefix).1-254 的 5013 …"
        LanScanner.scan(prefix: prefix) { hit in
            // 第一个回应的主机直接回填
            host = hit.ip
            scanSummary = "先回应的：\(hit.ip) \(hit.rttMs)ms\n\(hit.replyHex)"
        } completion: { hits in
            scanning = false
            if hits.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机在 5013 回应 RTCP ping。\n说明仪表还没进入投屏接收状态（或端口不是 5013）。"
            } else {
                scanSummary = hits.map { "\($0.ip)  \($0.rttMs)ms  ×\($0.replyCount)  \($0.replyHex)" }
                    .joined(separator: "\n")
            }
        }
    }

    private func runTcpScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        tcpScanning = true
        scanSummary = "TCP 扫描 \(prefix).1-254 的 8443 …"
        LanScanner.tcpScan(prefix: prefix) { ip in
            host = ip
            scanSummary = "8443 开着：\(ip)（已回填仪表 IP）"
        } completion: { ips in
            tcpScanning = false
            if ips.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机开着 8443。\n可以试试「填入网关地址 .1」，或确认仪表真的进入了投屏接收态。"
            } else {
                scanSummary = "开着 8443 的主机（已回填最后一个）：\n" + ips.joined(separator: "\n")
            }
        }
    }
}
