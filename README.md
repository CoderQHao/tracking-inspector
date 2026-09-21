<p align="center">
  <img src="Resources/AppIcon.png" width="112" alt="Tracking Inspector 应用图标">
</p>

# Tracking Inspector

在 Mac 上直观查看 iOS Debug 埋点。支持 USB / 局域网连接，运行无需 Python 或其他开发环境。

iOS App 需接入 [采集协议](Docs/protocol.md)。

## 下载

[下载最新 DMG](https://github.com/CoderQHao/tracking-inspector/releases/latest)，打开后将应用拖入 `Applications`。

支持 **macOS 13+、Apple Silicon 和 Intel**。目前使用 ad-hoc 签名，尚未经过 Apple 公证，首次打开可能被系统拦截；Release 附带 `SHA256SUMS` 校验文件。

## 功能

- 同时查看最多 8 台设备；USB 优先，已配对的局域网连接可在拔线后接续。
- 搜索参数、按设备和事件筛选，一键只看或排除事件，保存常用筛选。
- 比较两条事件的字段差异，从参数直接创建校验规则并预览异常。
- 保存调试记录，离线回看、搜索和分析。

![多设备事件与参数详情](Docs/images/multi-device.png)

![从字段创建校验规则并预览异常](Docs/images/guided-rules.png)

## 使用

1. 在手机运行已接入采集协议的 Debug App。
2. **USB**：连接、解锁并信任 Mac，在观察台选择设备。
3. **无线**：两端连接可互通的局域网，手机开启无线读取并复制连接信息；Mac 点击「连接设备… → 粘贴并连接」。也支持自动发现和手动输入地址。
4. 操作手机，查看事件；选中一条事件「设为对比基准」，再选另一条即可比较。

无线连接失败时检查局域网权限、地址和配对码，以及 VPN 是否允许局域网流量。iOS 挂起 App 时读取会暂停，恢复运行后自动重连。

事件保留在本机，实时缓存最多 2,000 条 / 16 MiB；仅在主动保存时写入文件。截图使用开发测试数据，应用内没有模拟设备或演示数据。

## 开发

需要 Xcode 16+；Node.js 仅用于运行 JavaScript 测试。

```sh
swift test --build-system native --enable-swift-testing --disable-xctest
node --test Tests/*.test.mjs
bash Scripts/build-dmg.sh
```

产物位于 `dist/`。发布时更新 `Resources/Info.plist` 版本号、添加 `Docs/releases/vX.Y.Z.md`，主分支 CI 通过后推送对应标签，GitHub Actions 会自动测试、构建和发布。
