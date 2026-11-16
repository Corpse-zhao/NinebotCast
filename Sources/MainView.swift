import SwiftUI
import PhotosUI
import UIKit
import CoreImage

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
    @State private var chunk1400 = true
    @State private var gopTen = true
    @State private var pingOnly = false
    @State private var showTools = false       // 找 IP 工具折叠
    @State private var showAdvanced = false    // 协议开关折叠
    @State private var showDiag = false        // 诊断折叠
    @State private var showPrereq = true       // 关键前提默认展开（新手必读）
    @State private var scanning = false
    @State private var tcpScanning = false
    @State private var probing = false
    @State private var scanSummary = ""
    @State private var diagText = Diag.tail(16)
    @State private var localIP = "-"

    // 图片：先选进 pending，预览确认后才生效
    @State private var pickedItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var confirmedImage: UIImage?
    @State private var imageConfirmed = false
    @State private var showImagePreview = false

    // 视频：同样确认制
    @State private var pickedVideoItem: PhotosPickerItem?
    @State private var pendingVideoURL: URL?
    @State private var confirmedVideoURL: URL?
    @State private var videoConfirmed = false

    @State private var sourceIndex = 0         // 0 测试图 1 图片 2 视频 3 摄像头
    @State private var rotationIndex = 0       // 0/90/180/270
    @State private var cameraPositionIndex = 0 // 0 后置 1 前置

    private static let previewContext = CIContext(options: nil)

    var body: some View {
        NavigationStack {
            Form {
                versionBanner
                connectionSection
                sourceSection
                castSection
                statusSection
                diagSection
                footnoteSection
            }
            .navigationTitle("Ninebot Cast")
            .onAppear {
                localIP = LanScanner.localIPv4() ?? "未连 Wi-Fi"
                diagText = Diag.tail(16)
                Diag.log("MainView 出现，版本 \(AppVersion.display)")
            }
            .onChange(of: pickedItem) { item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    await MainActor.run {
                        pendingImage = image
                        imageConfirmed = false   // 新图必须重新确认
                    }
                }
            }
            .onChange(of: pickedVideoItem) { item in
                guard let item else { return }
                Task {
                    // 视频先拷到临时目录再交给播放源（AVAssetReader 需要本地文件 URL）
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cast-video-\(UUID().uuidString).mp4")
                    do {
                        try data.write(to: url)
                    } catch {
                        await MainActor.run { scanSummary = "视频保存失败：\(error.localizedDescription)" }
                        return
                    }
                    await MainActor.run {
                        pendingVideoURL = url
                        videoConfirmed = false   // 新视频必须重新确认
                    }
                }
            }
            .onChange(of: sourceIndex) { _ in applySource() }
            .onChange(of: rotationIndex) { _ in applySource() }
            .onChange(of: cameraPositionIndex) { _ in
                if sourceIndex == 3 { applySource() }
            }
            .sheet(isPresented: $showImagePreview) {
                imagePreviewSheet
            }
        }
    }

    // MARK: - 顶部版本横幅（装没装对包，一眼分辨）
    private var versionBanner: some View {
        Section {
            HStack {
                Text("v\(AppVersion.short) (\(AppVersion.build))")
                    .font(.title2)
                    .bold()
                    .monospacedDigit()
                Spacer()
                Text("低于 0.14 = 旧包")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 连接设置
    private var connectionSection: some View {
        Section("仪表连接") {
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

            DisclosureGroup("①②③ 找仪表 IP（扫不到先看这里）", isExpanded: $showPrereq) {
                Text("关键前提：仪表必须已由九号自己的巡航逻辑进入投屏接收态（官方 App 车辆页 → 仪表投屏导航 → 投屏导航，等仪表出地图）。然后从后台强退九号出行（上滑划掉）——它活着就会占住本机 5012/5013 端口并持续心跳，我们的包根本发不出去（状态里出现「端口被占」就是这种情况）。iPhone 连上仪表热点后，IP 填热点详情页「路由器」那行，别填本机地址。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button {
                    fillGateway()
                } label: {
                    Label("① 填入网关 .1（热点由车机发 DHCP，网关通常就是它）",
                          systemImage: "1.circle")
                }
                Button {
                    runProbe()
                } label: {
                    Label(probing ? "体检中…" : "② 体检当前 IP（TCP 端口 + RTCP 5013）",
                          systemImage: "2.circle")
                }
                .disabled(probing)
                Button {
                    runTcpScan()
                } label: {
                    Label(tcpScanning ? "端口扫描中…（约 8 秒）" : "③ 扫全段端口（8443/80/443/5000…）",
                          systemImage: "3.circle")
                }
                .disabled(tcpScanning)
                Button {
                    runScan()
                } label: {
                    Label(scanning ? "RTCP 扫描中…（约 2 秒）" : "扫全段 RTCP 5013（需仪表在接收态）",
                          systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(scanning)
                if !scanSummary.isEmpty {
                    Text(scanSummary)
                        .font(.footnote)
                        .monospaced()
                }
            }
        }
    }

    // MARK: - 画面来源（预览确认制）
    private var sourceSection: some View {
        Section("画面来源") {
            Picker("来源", selection: $sourceIndex) {
                Text("测试图").tag(0)
                Text("图片").tag(1)
                Text("视频").tag(2)
                Text("摄像头").tag(3)
            }
            .pickerStyle(.segmented)
            Picker("方向", selection: $rotationIndex) {
                Text("0°").tag(0)
                Text("90°").tag(1)
                Text("180°").tag(2)
                Text("270°").tag(3)
            }
            .pickerStyle(.segmented)

            if sourceIndex == 1 {
                photoFlow
            } else if sourceIndex == 2 {
                videoFlow
            } else if sourceIndex == 3 {
                cameraFlow
            } else {
                Text("内置测试图：彩条 + 移动方块，用于验证链路是否通。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    // 图片流程：选 → 预览 → 确认 → 才真正投
    private var photoFlow: some View {
        Group {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Label(confirmedImage == nil ? "选择图片" : "换一张图片",
                      systemImage: "photo.on.rectangle.angled")
            }
            if let pendingImage, !imageConfirmed {
                // 待确认：大图预览 + 确认按钮
                Button {
                    showImagePreview = true
                } label: {
                    previewImageView(pendingImage)
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .cornerRadius(8)
                        .overlay(alignment: .topTrailing) {
                            Text("待确认 · 点开预览")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
                                .padding(8)
                        }
                }
                .buttonStyle(.plain)

                Button {
                    confirmedImage = pendingImage
                    imageConfirmed = true
                    applySource()
                } label: {
                    Label("确认投这张图", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            } else if let confirmedImage, imageConfirmed {
                HStack(spacing: 12) {
                    previewImageView(confirmedImage)
                        .frame(width: 96, height: 64)
                        .clipped()
                        .cornerRadius(6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已确认，将铺满仪表（超出部分裁掉）")
                            .font(.footnote)
                        Text("方向变了会自动重新铺满")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    // 视频流程：选 → 确认 → 才真正投
    private var videoFlow: some View {
        Group {
            PhotosPicker(selection: $pickedVideoItem, matching: .videos) {
                Label(confirmedVideoURL == nil ? "选择视频" : "换一个视频",
                      systemImage: "video.badge.plus")
            }
            if let pendingVideoURL, !videoConfirmed {
                Text("已选 \(pendingVideoURL.lastPathComponent)，循环播放。")
                    .font(.footnote)
                Button {
                    confirmedVideoURL = pendingVideoURL
                    videoConfirmed = true
                    applySource()
                } label: {
                    Label("确认投这段视频", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            } else if let confirmedVideoURL, videoConfirmed {
                Text("已确认 \(confirmedVideoURL.lastPathComponent)，独立线程解码（不再卡顿），循环播放；方向变了自动生效。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var cameraFlow: some View {
        Group {
            Picker("摄像头", selection: $cameraPositionIndex) {
                Text("后置").tag(0)
                Text("前置").tag(1)
            }
            .pickerStyle(.segmented)
            Text("首次使用会弹相机权限，允许后才开始出画面。iOS 限制：退后台后摄像头会停止采集，画面停在最后一帧但流不断；图片和视频源退后台不受影响。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    /// 按当前方向渲染「仪表上会看到的样子」
    private func previewImageView(_ image: UIImage) -> some View {
        let preset = DashboardPreset.all[presetIndex]
        let rotation = [0, 90, 180, 270][rotationIndex]
        let rendered = Self.renderPreview(image,
                                          rotation: rotation,
                                          width: preset.width,
                                          height: preset.height)
        return Image(uiImage: rendered)
            .resizable()
            .scaledToFill()
    }

    /// 用 CI 走一遍和投屏完全相同的旋转+铺满管线，所见即所得
    static func renderPreview(_ image: UIImage, rotation: Int, width: Int, height: Int) -> UIImage {
        guard var ci = CIImage(image: image) else {
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in }
        }
        switch rotation {
        case 90: ci = ci.oriented(.right)
        case 180: ci = ci.oriented(.down)
        case 270: ci = ci.oriented(.left)
        default: break
        }
        ci = FrameRenderer.aspectFillTransform(ci, destWidth: width, destHeight: height)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cg = previewContext.createCGImage(ci, from: rect) {
            return UIImage(cgImage: cg)
        }
        return UIGraphicsImageRenderer(size: rect.size).image { _ in }
    }

    // MARK: - 投屏控制
    private var castSection: some View {
        Section {
            DisclosureGroup("高级设置（一般不用动）", isExpanded: $showAdvanced) {
                Toggle("关键帧重发", isOn: $duplicateKeyframes)
                Toggle("分片 1400 字节（关 = 1380，APK 值）", isOn: $chunk1400)
                Toggle("关键帧每 10 帧（官方 gopSize）", isOn: $gopTen)
                Toggle("只发 ping（不编码，用于排查）", isOn: $pingOnly)
            }

            if engine.isRunning {
                Button(role: .destructive) {
                    engine.stop()
                } label: {
                    Label("停止投屏", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    engine.start(preset: DashboardPreset.all[presetIndex],
                                 host: host,
                                 duplicateKeyframes: duplicateKeyframes,
                                 packetSize: chunk1400 ? 1400 : 1380,
                                 gop: gopTen ? 10 : Int(DashboardPreset.all[presetIndex].fps),
                                 pingOnly: pingOnly)
                } label: {
                    Label(pingOnly ? "开始（仅 ping 排查）" : "开始投屏", systemImage: "play.rectangle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 状态
    private var statusSection: some View {
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
    }

    // MARK: - 诊断（折叠）
    private var diagSection: some View {
        Section {
            DisclosureGroup("诊断日志（出问题发这段给我）", isExpanded: $showDiag) {
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
        }
    }

    // MARK: - 脚注
    private var footnoteSection: some View {
        Section {
            DisclosureGroup("协议要点（逆向自官方 APK）", isExpanded: .constant(false)) {
                Text("视频 RTP 20 字节扩展头 · PT 32 · 1380 字节分片；时间戳毫秒 · 每帧带 SPS/PPS · 关键帧每秒 1 个；RTCP ping/pong 每秒 1 次；本机端口绑定 5012/5013；8443 只是车机常见网页端口，投屏通道只有 UDP 5012/5013。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Text("版本 \(AppVersion.display)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 图片预览 sheet
    private var imagePreviewSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let pendingImage {
                    previewImageView(pendingImage)
                        .frame(maxHeight: 360)
                        .clipped()
                        .cornerRadius(12)
                        .padding(.horizontal)
                    Text("以上是仪表上实际会显示的画面（已按当前方向铺满 \(DashboardPreset.all[presetIndex].width)×\(DashboardPreset.all[presetIndex].height)，超出部分裁掉）")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                    Button {
                        confirmedImage = pendingImage
                        imageConfirmed = true
                        applySource()
                        showImagePreview = false
                    } label: {
                        Label("确认投这张图", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("图片预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showImagePreview = false }
                }
            }
        }
    }

    // MARK: - 来源应用逻辑（只有确认过的素材才会真正上屏）
    private func applySource() {
        let rotation = [0, 90, 180, 270][rotationIndex]
        switch sourceIndex {
        case 0:
            engine.useTestImage()
        case 1:
            if imageConfirmed, let confirmedImage {
                engine.usePhoto(confirmedImage, rotation: rotation)
            } else {
                engine.useTestImage()
            }
        case 2:
            if videoConfirmed, let confirmedVideoURL {
                engine.useVideo(url: confirmedVideoURL, rotation: rotation)
            } else {
                engine.useTestImage()
            }
        case 3:
            engine.useCamera(position: cameraPositionIndex == 0 ? .back : .front,
                             rotation: rotation)
        default:
            break
        }
    }

    // MARK: - 找 IP 工具
    private func fillGateway() {
        guard let gateway = LanScanner.gatewayGuess() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        host = gateway
        scanSummary = "已填入网关 \(gateway)（车机热点自己发 DHCP，网关通常就是它）。\n填好点「② 体检」验一下，再开始投屏。"
    }

    private func runProbe() {
        let ip = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            scanSummary = "先填一个 IP 再体检"
            return
        }
        guard ip != localIP else {
            scanSummary = "这是本机地址（\(ip)），换仪表的 IP"
            return
        }
        probing = true
        scanSummary = "体检 \(ip) …（端口 + RTCP，约 3 秒）"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LanScanner.probe(ip: ip)
            DispatchQueue.main.async {
                probing = false
                var lines: [String] = []
                if result.openPorts.isEmpty {
                    lines.append("TCP：常见端口都没开")
                } else {
                    lines.append("TCP 开放：\(result.openPorts.map { String($0) }.joined(separator: ", "))")
                }
                lines.append(result.rtcpPong
                             ? "RTCP 5013：有 pong（\(result.rttMs)ms）"
                             : "RTCP 5013：无回应（不在接收态，或 IP 不对）")
                if !result.pongHex.isEmpty {
                    lines.append(result.pongHex)
                }
                scanSummary = lines.joined(separator: "\n")
            }
        }
    }

    private func runTcpScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        tcpScanning = true
        scanSummary = "扫 \(prefix).1-254 的 8443/80/443/5000/8080/8000/9000 …"
        LanScanner.tcpScan(prefix: prefix) { ip in
            host = ip
            scanSummary = "发现有开放端口：\(ip)（已回填）"
        } completion: { hits in
            tcpScanning = false
            if hits.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机开放这些端口。\n换「① 网关 .1」或「扫 RTCP 5013」试试——端口只是线索，投屏通道是 UDP 5012/5013。"
            } else {
                scanSummary = hits
                    .map { "\($0.ip)  端口 \($0.ports.map { String($0) }.joined(separator: "/"))" }
                    .joined(separator: "\n")
            }
        }
    }

    private func runScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        scanning = true
        scanSummary = "扫描 \(prefix).1-254 的 5013（含广播探测）…"
        LanScanner.scan(prefix: prefix) { hit in
            host = hit.ip
            scanSummary = "先回应的：\(hit.ip) \(hit.rttMs)ms\n\(hit.replyHex)"
        } completion: { hits in
            scanning = false
            if hits.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机在 5013 回应（本机已排除）。\n仪表多半还没进入投屏接收态——先在仪表/官方 App 里进接收态，再扫一次。"
            } else {
                scanSummary = hits.map { "\($0.ip)  \($0.rttMs)ms  ×\($0.replyCount)  \($0.replyHex)" }
                    .joined(separator: "\n")
            }
        }
    }
}
