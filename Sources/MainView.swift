import SwiftUI

struct MainView: View {
    @StateObject private var engine = CastEngine()
    @State private var presetIndex = 0
    @State private var host = "192.168.1.162"

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
                    Text("先在 设置 > Wi-Fi 手动连接仪表热点，再填仪表 IP（iOS 无 Wi-Fi Direct 公开 API，无法自动连接）。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("投屏（骨架版：测试图）") {
                    Button {
                        engine.start(preset: DashboardPreset.all[presetIndex], host: host)
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
                }

                Section("待核对协议项") {
                    Text("1. RTP payload type / 时钟基准 / SSRC（当前 96 / 90kHz）")
                    Text("2. UDP 5013 心跳与控制包字节格式")
                    Text("3. 七寸 KCP conv 参数与 ACK 通路")
                    Text("4. 相册 / 摄像头 / 屏幕采集（下一阶段）")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Ninebot Cast")
        }
    }
}
