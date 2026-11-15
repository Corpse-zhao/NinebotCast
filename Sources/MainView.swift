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
    @State private var scanSummary = ""
    @State private var diagText = Diag.tail(16)
    @State private var localIP = "-"

    var body: some View {
        NavigationStack {
            Form {
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

                Section("找不到 IP？直接扫") {
                    Button {
                        runScan()
                    } label: {
                        Label(scanning ? "扫描中…（约 2 秒）" : "扫描网段，找谁在 5013 回应",
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(scanning)
                    if !scanSummary.isEmpty {
                        Text(scanSummary)
                            .font(.footnote)
                            .monospaced()
                    }
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
}
