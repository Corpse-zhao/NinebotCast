# NinebotCast（iOS 复刻 ninebot_pro 投屏）

复刻 [xmz28/ninebot_pro](https://github.com/xmz28/ninebot_pro) 的 iOS 端投屏：把测试图/相册/摄像头/屏幕画面投到九号电动车仪表。

原仓库只分发 Android APK（无源码），本项目按其 README 公开的协议参数从零重写 iOS 版。

## 同类项目调研（2026-11-15）

| 项目 | 路线 | 对本项目的价值 |
|---|---|---|
| [xmz28/ninebot_pro](https://github.com/xmz28/ninebot_pro) | Android APK，UDP 5012/5013 + RTP | 初始协议参照（20 字节头 / PT 32 / 毫秒时间戳 / 1380 分片） |
| [Xiaolangs/ninebot-cast-tweak](https://github.com/Xiaolangs/ninebot-cast-tweak) | iOS 九号出行 6.10.9 Ghidra 逆向 + 越狱 tweak | **最有价值**：投屏导航不是镜像屏幕，而是手机自绘 HUD（240×320 / 25fps / **500 kbps** / gop 10 / MTU 1400）；`RTPStandard==2` 才带视频专用扩展头；**RTCP APP 心跳 = 子类型 5、参数 [0,2]**；还有 BLE 与 KCP 两条备用通道 |
| [KaruMono/NinebotEnhance](https://github.com/KaruMono/NinebotEnhance) | Android LSPosed 模块，接管九号自己的编码发送链路 | **已在 M5P（车型 14103，仪表 848×480，Wi-Fi Direct H.264）实测**；并明确「是否开机由九号自己的巡航逻辑检查」——仪表必须先进投屏接收态 |
| [xmz28/ForzaDash](https://github.com/xmz28/ForzaDash) | ESP32 USB/Wi-Fi CAN 注入仪表（0x170/0x210/0x212） | 与视频投屏无关，但证明仪表数据面可注入，可作后续「速度/功率叠加」参考 |
| [OpenXPlay/OpenXPlay](https://github.com/OpenXPlay/OpenXPlay) | CarPlay 转发到安卓车机 | 只解释作者视频里 8443 那套 Web 接收端，不经九号仪表通道 |

据此修正的实现：心跳改官方 `APP subtype 5 / [0,2]`（保留计数变体兜底）、分片 1400/1380 可切换、gop 10、新增 848×480 25fps 800kbps 预设。

## 版本记录

| 版本 | 变更 |
|------|------|
| 0.14.0 (14) | **视频不再卡**：解码移出发送线程（独立解码线程 + 3 缓冲轮换，发送端零等待）；**摄像头修复闪退**：先走 requestAccess 权限流程再配置 session，每步打诊断日志；**图片预览确认制**：选图后大图预览（按当前方向渲染出仪表实际画面）+「确认投这张图」；**视频确认制**；UI 重排：来源/方向改分段选择器，扫描工具/高级设置/诊断/协议要点全部折叠收纳，开始/停止改大按钮 |
| 0.13.0 (13) | **图片改铺满（aspect-fill）+ 方向可旋转 0/90/180/270**；新增**视频投屏**（相册选视频，AVAssetReader 循环解码、按投屏帧率取帧）与**摄像头投屏**（前后置，取最新帧；退后台系统会停采集，画面停在最后一帧但流不断）；后台保活增加音频中断/媒体服务重置自动恢复 |
| 0.12.0 (12) | 新增**相册图片投屏**：PhotosPicker 选图 → 等比缩放居中补黑 → 按帧率持续重发；可一键清除回到测试图。视频/摄像头投屏排后续版本 |
| 0.11.0 (11) | **里程碑：仪表开始回 pong（往返 11-15ms）**，确认 192.168.1.1 = 仪表、5013 通、官方心跳格式正确。新增后台保活：静音 AVAudioEngine + 禁止锁屏，退后台不再断流（UIBackgroundModes=audio 真正生效） |
| 0.10.0 (10) | **修真凶**：九号出行在后台会占住本机 UDP 5012/5013，导致我们的连接 failed、send 静默丢弃（帧数在涨但一个包都没发出去）。现在端口被占自动降级为临时端口重连，并在状态区提示「强退九号出行」；日志记录实际本地端口 |
| 0.9.0 (9) | 心跳改官方格式（RTCP APP 子类型 5、参数 [0,2]，同时保留计数变体）；RTP 分片 1400/1380 可切；关键帧间隔 gop 10；新增 848×480 25fps 800kbps（官方 HUD 参数）预设；界面提示改为「必须先进巡航接收态 + 把官方 App 切后台」 |
| 0.8.0 (8) | 端口不再只赌 8443：TCP 扫 8443/80/443/5000/8080/8000/9000 并显示每台开了哪些；RTCP 扫描加广播探测；新增「体检当前 IP」（端口+RTCP+pong 原文）；①网关 ②体检 ③扫段 三步引导 |
| 0.7.0 (7) | 扫描排除本机（热点下手机是 .3，自己 ping 自己被误判成仪表）；新增 TCP 8443 端口扫描找仪表；pong 只认 85 CC 00 04 头（实测仪表回包字段与 APK 假设不同）；新增「填入网关 .1」 |
| 0.6.0 (6) | 专属头像 App 图标；版本号大字放界面顶部（防装错旧包）；产物按版本命名 |
| 0.5.0 (5) | 防闪退加固：修 `CMBlockBuffer` 越界读、VT 回调 refcon 悬垂、后台线程碰 UIKit；串行队列自锁改为 specific-key 派发；新增文件诊断日志（闪退后下次启动可查）、网段扫描找仪表 IP、「只发 ping」隔离开关 |
| 0.4.0 (4) | 协议对齐 APK 逆向：20 字节扩展头 / PT 32 / 毫秒时间戳 / 1380 分片 / 每帧带 SPS/PPS |
| 0.3.0 | 首次可运行的骨架（标准 RTP 12 字节头） |

## 当前进度（骨架版）

- [x] VideoToolbox H.264 硬编码（Annex-B 输出，关键帧自动带 SPS/PPS）
- [x] 标准 RTP 打包（RFC 6184，Single NALU + FU-A 分片）
- [x] UDP 视频通道 5012 / 控制保活 5013（Network.framework）
- [x] KCP 通道（七寸预设，C 源码直编译）
- [x] 测试图源（色条 + 移动滑块 + 帧计数，验证仪表出画面）
- [ ] RTP 参数与仪表抓包核对（payload type / 时钟 / SSRC）
- [ ] 5013 心跳与控制包字节格式（当前为占位字节）
- [ ] 七寸 KCP conv / ACK 通路核对
- [ ] 相册、摄像头、ReplayKit 屏幕采集
- [ ] 4.3寸 JPEG 模式

## 投屏预设（来自原项目 README）

| 预设 | 分辨率 | 编码与传输 | 帧率 | 码率 |
|------|--------|-----------|------|------|
| 五寸（KZ110 已验证） | 848×480 | H.264 / RTP | 20 | 2000 kbps |
| 七寸（待实测） | 1024×600 | H.264 / RTP+KCP | 25 | 2000 kbps |
| 4.3寸（测试） | 480×272 | JPEG / RTP | 10 | — |

## 使用

1. Actions 构建出未签名 IPA（artifact：`NinebotCast-unsigned-ipa`），自签/免费签名安装。
2. 在仪表或官方 App 中开启投屏模式，iPhone 在 设置 > Wi-Fi **手动连接**仪表热点（iOS 没有 Wi-Fi Direct 公开 API，无法像 Android 那样自动组网）。
3. 打开 App，选预设、填仪表 IP，点"开始投屏（测试图）"。

## 已知 iOS 平台限制

- 无 Wi-Fi Direct API：只能手动连热点，连仪表 IP 发 UDP。
- 后台投屏：App 带 background audio 模式可部分保活；摄像头后台会被系统强制停止（同原版 iOS 行为）。
- 免费签名 7 天过期，需定期重签。

## 构建

本地无 Mac 时走 GitHub Actions（macos-14 + xcodegen + xcodebuild archive 不签名打包）。

本地构建：

```bash
xcodegen generate
xcodebuild archive -project NinebotCast.xcodeproj -scheme NinebotCast \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath build/NinebotCast.xcarchive CODE_SIGNING_ALLOWED=NO
```

## 协议

本项目代码 MIT。KCP 来自 [skywind3000/kcp](https://github.com/skywind3000/kcp)（其自带许可证）。与九号公司无官方关联。
