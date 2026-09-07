# SwiftExample

一个最小 iOS App，演示如何打开 Producer、发送日志、接收异步结果并关闭 Producer。

## 要求

- Xcode 14.3.1+
- iOS 13.0+

## 运行

```bash
cd Producer/Examples/SwiftExample
open SwiftExample.xcworkspace
```

workspace 使用仓库根目录的本地 Swift package。选择 App target 和一个 iOS 设备或
Simulator 后运行。

如需在自己的工程中复用示例：

1. 添加本仓库为 Swift Package 依赖。
2. 将 `VolcengineTLSProducer` product 加入 App target。
3. 参考 `ViewController.swift` 配置 endpoint、region、projectID、topicID 和凭证。
4. 只向你有权限的 TLS project/topic 发送测试日志。

不要把真实 AK/SK 提交到源码仓库。生产环境建议使用临时凭证，并通过
`updateCredentials(_:)` 完成刷新。

更多说明见[快速开始](../../../docs/getting-started/quick-start.md)和
[日志模型](../../../docs/reference/log-model.md)。

## ATS

TLS endpoint 使用 HTTPS，示例不需要 `NSAllowsArbitraryLoads`。SDK 使用系统默认
TLS 信任，不提供 trust-all 开关。

## 文件说明

| 文件 | 作用 |
|---|---|
| `AppDelegate.swift` | App 入口 |
| `SceneDelegate.swift` | iOS 13 scene 生命周期 |
| `ViewController.swift` | 打开 Producer、发送日志并显示结果 |
| `Info.plist` | App 配置；不包含 ATS 绕过 |
