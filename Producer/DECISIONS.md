# VolcengineTLSProducer — 实施决策索引

> 本文件随 Producer 代码演进，记录实施期冻结决策。冲突时以 workspace 侧
> [Implementation Decision Ledger](../../docs/research/tls-ios-producer-sdk-implementation-decision-ledger.md) 为准。
> （相对路径仅为文档导航；仓库独立分发时以本文件为权威。）

## 当前状态：Development Preview / blocked on external Beta gates

- C Core 发布门禁未满足 → `RealCoreAdapter` blocked，当前所有 Core 行为由 `FakeCoreAdapter`（仅测试）提供。
- 无 macOS/Xcode 工具链 → 编译与测试证据 pending，不得宣称 Beta。

## 冻结决策摘要（2026-08-27）

1. Producer-only；Swift-first public API；ObjC public facade / contextFlow / 自动 STS Provider / XCFramework 均为 P1。
2. 第一阶段最低 deployment target = iOS 13.0（P0，不可降级）。
3. `add(mode:)`：`.normal`（默认）进入批量窗口；`.immediate` 封批并唤醒 sender，仍异步，不等待网络/ACK。
4. `updateDestination` 为 current-target 语义：旧 WAL/积压后续改投新目标。不做 backlog fail-closed、不做 target fingerprint/manifest v3。
5. `close(timeout:)` 成功 = 本地 worker/session 安全停止 + 本地持久化完成；不表示远端全部送达。无 `CloseReport.persistedForRecovery`。
6. P0 公共 API 仅：`open / add(mode:) / updateCredentials / updateDestination / close`。
   `flush`（远端终态语义）、`resumeDelivery`、`deliverySuspended-auth`/`retryDelayed` 公共状态、rich metrics、
   `updateMetadataIfIdle`/`pendingBacklog` 均不进入 P0 public API。
7. `SendResult` 稳定最小字段：`status / rawBytes / compressedBytes / requestID? / error?`。
8. 静态 AK/SK/STS 初始化 + 整组原子更新 = P0；自动 STS Provider = P1。
9. 安全：仅 HTTPS + ATS/系统证书校验；无 trust-all 开关；凭证不入日志/WAL/文件名；redirect 仅同 scheme+host。
10. 不承诺 exactly-once；不承诺 App 被强杀后继续实时上传；buffered WAL 与 sync WAL 的 crash/掉电边界分别说明。

## 工程结构决策

- `CoreAdapter` = Swift `public protocol`（`Sources/VolcengineTLSProducer/Core/`），文档注释明确 `PROVISIONAL — internal seam, not a public API contract`。必须 public 的原因：`ProducerTestSupport` 是独立非 test target，无法 `@testable` 访问 internal 协议；Wave 3 RealCoreAdapter 接入时可重塑 seam。
- `FakeCoreAdapter` 位于 `Tests/ProducerTestSupport/`，仅测试编译，不进入发布源码。
- `TLSProducerBridge` 使用 Objective-C（.m/.h），不使用 .mm（SwiftPM 兼容性）。
- `CTLSProducerCore` 为占位 target；`CORE_VERSION` 标记 BLOCKED，直到真实 Core release 通过门禁。
- CocoaPods 与 SwiftPM 编译同一份 `Producer/Sources/` 源码，不维护两套实现。

## 已知限制与 Wave 3 跟进项（API reviewer 2026-08-27）

- `Producer`/`ProducerConfiguration` 未标注 `Sendable`：Swift 5.8 模式仅警告，Swift 6 模式前需评估 `@unchecked Sendable`。
- `Producer` 无 `deinit`：memory 模式未显式 close 的 best-effort 取消与 persistent closing registry 随 RealCoreAdapter 落地（设计 §5.4）。
- `close` 从 `.failed` 状态抛 `.invalidState`：公共 API 不可达（open 失败不返回 Producer）；RealCoreAdapter 接入后 failed-open 可能有部分初始化资源，需评估幂等清理路径（设计 §6.1）。
- `BufferFullPolicy.block` 在 BundledCoreAdapter 降级为 `.reject`，RealCoreAdapter 实现。
- `TLSProducerDirectory.isURL:insideContainerBaseURL:` 的 `baseURL` 当前标注 TESTING ONLY；设计 §9.2 的 App Group 自定义目录（不在 NSHomeDirectory 下）需要 Wave 3 提供正式校验入口。
- `TLSLifecycleManager` 必须在主线程使用（通知恒在主线程投递）。
- `TLSRedactingLogger` 使用 `NSLog` 单一日志入口，无 debug/release 级别开关；Wave 3 评估接入统一日志门面（os_log / 可注入 logger）。脱敏合同（仅 method/脱敏URL/status/duration/requestID/字节数，mask authorization/x-tls-*）不受影响。
