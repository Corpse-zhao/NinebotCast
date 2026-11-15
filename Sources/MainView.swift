import SwiftUI

struct MainView: View {
    @StateObject private var engine = CastEngine()
    @State private var presetIndex = 0
    @State private var host = "192.168.1.13"
    @State private var duplicateKeyframes = true

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
                    Toggle("关键帧重发", isOn: $duplicateKeyframes)
                    Text("先在仪表或官方 App 的巡航投屏里让仪表进入投屏状态（官方是点车辆页巡航入口）。iPhone 在 设置 > Wi-Fi 连上仪表热点后，把这里填成热点详情页里「路由器」那行的地址。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("投屏（协议已对齐官方 APK）") {
                    Button {
                        engine.start(preset: DashboardPreset.all[presetIndex],
                                     host: host,
                                     duplicateKeyframes: duplicateKeyframes)
                    } label: {
                        Label("开始投屏（测试图）", systemImage: "play.rectangle.fill")
                    }
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

                Section("协议要点（逆向自官方 APK）") {
                    Text("视频 RTP 20 字节扩展头 · PT 32 · 1380 字节分片")
                    Text("时间戳毫秒 · 每帧带 SPS/PPS · 关键帧每秒 1 个")
                    Text("RTCP ping/pong 每秒 1 次（20 字节）")
                    Text("本机端口绑定 5012/5013")
                }
            }
            .navigationTitle("Ninebot Cast")
        }
    }
}
