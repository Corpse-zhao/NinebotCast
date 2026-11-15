# NinebotCast（iOS 复刻 ninebot_pro 投屏）

复刻 [xmz28/ninebot_pro](https://github.com/xmz28/ninebot_pro) 的 iOS 端投屏：把测试图/相册/摄像头/屏幕画面投到九号电动车仪表。

原仓库只分发 Android APK（无源码），本项目按其 README 公开的协议参数从零重写 iOS 版。

## 版本记录

| 版本 | 变更 |
|------|------|
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
