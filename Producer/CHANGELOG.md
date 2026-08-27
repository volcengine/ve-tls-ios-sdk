# Changelog

All notable changes to VolcengineTLSProducer are documented in this file.

本项目在离开 Development Preview 之前不承诺 Semantic Versioning 兼容性；
`CoreAdapter` 等 PROVISIONAL seam 可能随时重塑。

## 0.0.2 — Development Preview (2026-08-28)

### Added

- **Real C Core 集成**：vendor `ve-tls-c-sdk` v0.3.1（commit `08f33af`），
  替换占位 target。提供 persistent WAL、retry、LZ4 压缩、签名、HTTP 发送。
- **`RealCoreAdapter`**：Swift `CoreAdapter` 实现，桥接 C Core ABI。
  `Producer.open` 在有 `destination` 时使用 RealCoreAdapter，否则用 BundledCoreAdapter。
- **`TLSRealCoreAdapter`**（ObjC）：C Core 的 ObjC 包装，含 NSURLSession HTTP 桥接。
- **`ProducerConfiguration.destination`**：新增可选字段，用于 RealCoreAdapter 的 endpoint/region/topic。
- **集成测试**：7 个 RealCoreAdapter 端到端测试（创建/发送/更新/关闭）。

### Fixed

- 修复 8 个编译/运行时 bug（NSAssert、internal 关键字、CheckedContinuation、NSCopying、
  LogValue 编码、符号链接容器逃逸等），全部 184 测试通过。

### Evidence

- iOS Simulator 26.5 (iPhone 17)：184/184 PASS
- C Core CI：asan-ubsan/shared-abi/static-release PASS
- 旧 SDK 零改动

## 0.0.1 — Development Preview (2026-08-27)

首个 Development Preview 版本。**不是 Beta 发布**：C Core 发布门禁未满足，
编译/真机证据 pending。

### Added

- **Swift 公共 API（P0 冻结）**：
  `Producer.open(configuration:credentials:onSendResult:)`、
  `add(_:mode:)`、`updateCredentials(_:)`、`updateDestination(_:)`、
  `close(timeout:)`。
- **值模型**：`ProducerConfiguration`（默认值对齐 SLS iOS wrapper：
  batch 1024/1MiB/3s、buffer 64MiB reject、sendConcurrency 1、LZ4、
  connect 10s、request 15s、maxLogAge 7d、rewriteTimestamp、retain、
  source "iOS"）、`Credentials`、`Destination`、`LogEvent`/`LogValue`、
  `ProducerMetadata`、`SendResult`、`ProducerError`、`AddMode`。
- **`BundledCoreAdapter`**：PROVISIONAL 内存实现，支撑 `Producer.open`
  （无网络/持久化/压缩/签名/重试；非发布行为承诺）。
- **`CoreAdapter`**：PROVISIONAL 内部 seam（`public` 仅供测试 target 链接，
  非公共 API 合同）。
- **`TLSProducerBridge`**：Objective-C 桥骨架（redacting logger、
  thread assertions、serial queue factory、`TLSRealCoreAdapter` 占位）。
- **`CTLSProducerCore`**：C 占位 target（真实 C Core 被发布门禁阻塞，
  见 `CORE_VERSION`）。
- **工程**：SwiftPM `Package.swift`（iOS 13、Swift 5.8）与 CocoaPods
  podspec，编译同一份 `Producer/Sources` 源码；Privacy manifest。
- **测试（已编写，执行待 macOS + Xcode）**：
  - `ContractTests`：默认值、日志校验、编码合同、add 模式、destination
    校验、凭证脱敏、生命周期；
  - `BridgeTests`：FakeCoreAdapter 并发/回调/close 协调、ObjC helper；
  - `ConsumerIntegrationTests`：纯消费者视角（无 `@testable`）的
    smoke/默认值/凭证与 destination 轮换/非法日志拒绝/close 后拒绝；
  - `TransportTests`：NSURLSession transport 状态矩阵/redirect/timeout/
    cancel/late callback/脱敏（16 个，NSURLProtocol 离线 stub）；
  - `PersistenceTests`：producerID 校验、目录创建与属性、容器边界、
    生命周期（30 个）。
- **示例**：`Producer/Examples/SwiftExample`（最小 iOS 13 App，local SwiftPM
  依赖 + 手写 `project.pbxproj`）。
- **文档**：`Producer/README.md`、`Producer/DECISIONS.md`、
  `Producer/THIRD_PARTY_NOTICES`。

### Evidence Boundary

- 代码已编写并经静态审查；**未编译、未运行**（开发机无 Apple 工具链）。
- 无模拟器/真机/BOE/soak/性能证据。
- C Core 发布门禁未满足，`RealCoreAdapter` blocked；不承诺
  persistent/retry/ACK/真实发送。
