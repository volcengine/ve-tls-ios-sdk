# 兼容性

Producer v2 支持原生 iOS、iPadOS 和 macOS，提供 Swift 与 Objective-C 接口。
Objective-C 业务代码无需添加 Swift 源文件，SDK 内部仍使用 Swift；接入步骤见
[Objective-C 接入](../getting-started/objective-c.md)。

## 产品平台

| 接入对象 | 最低系统 | 架构 | SwiftPM | CocoaPods | 说明 |
|---|---:|---|---|---|---|
| iPhone / iPad 真机 | iOS / iPadOS 13.0 | arm64 | 支持 | 支持 | 共用 iOS target |
| iOS Simulator（Apple Silicon Mac） | 随 Xcode runtime | arm64 | 支持 | 支持 | 可运行版本取决于已安装的 Simulator runtime |
| iOS Simulator（Intel Mac） | 随 Xcode runtime | x86_64 | 支持 | 支持 | 用于 Intel Mac 模拟器兼容 |
| 原生 macOS（Intel） | macOS 10.15 | x86_64 | 支持 | 支持 | 原生 macOS，不是 Simulator |
| 原生 macOS（Apple Silicon） | macOS 11.0 | arm64 | 支持 | 支持 | Apple Silicon 系统从 macOS 11 开始 |

包清单声明 iOS 13.0 和 macOS 10.15。某个 Xcode 版本可安装的最低 Simulator runtime
可能高于 iOS 13，这不改变 iPhoneOS 设备产物的 iOS 13 deployment target。

## 工具链

- Swift 5.8+
- Xcode 14.3.1+
- CocoaPods 使用支持当前 Xcode 工程格式的版本

SDK 源码保持 Swift 5.8 语言兼容，同时在 Swift 6 严格并发模式下执行构建检查。应用仍应使用
自己的最低和最高受支持 Xcode 完成发布构建。

## App Extension

Producer 可以在 iOS App Extension target 中使用，自动生命周期处理默认关闭。系统允许的完成
路径可显式调用 `close(timeout:)` 完成本地关闭。同一持久化目录不能由多个活跃 Producer 并发
占用；主 App 与 Extension 默认使用不同容器，不能仅凭相同 `producerID` 跨容器恢复。

不同类型 Extension 的执行时间、网络权限和容器配置不同。请在系统允许的执行时间内完成写入，
不要依赖主 App 的后台运行时间。

## macOS 行为

- `ProducerMetadata.source` 默认是 `"macOS"`；
- `automaticLifecycleHandling` 默认关闭，设为 `true` 也没有效果；
- App、菜单栏程序、daemon 和命令行工具应在可控退出路径显式调用 `close(timeout:)`；
- `.buffered` 和 `.sync` 可以在下一次启动时恢复未确认日志。

示例和退出顺序见[生命周期、App Extension 与 macOS](../guides/lifecycle-and-extensions.md)。

## 不支持的平台和接入方式

- Mac Catalyst
- tvOS
- watchOS
- visionOS
- Carthage 或手工发布的 XCFramework

安装步骤见[安装](../getting-started/installation.md)，隐私资源说明见[隐私说明](privacy.md)。
