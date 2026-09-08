# Changelog

VolcengineTLSProducer 的重要用户可见变更记录在此文件中。

## 2.0.1

- 修复 CocoaPods 接入时 module map 文件缺失导致的编译失败。
- 修复 SDK 路径包含空格时的 CocoaPods 编译失败。
- 请求 `User-Agent` 更新为 `volc-tls-ios/producer/v2.0.1`。

## 2.0.0 — 2026-09-07

### Added

- 提供 Swift 和 Objective-C Producer 接口，支持创建、写入、更新凭证、更新目标和关闭。
- 支持日志批处理、LZ4 压缩、并发发送、失败重试和异步发送结果回调。
- 支持 memory、buffered 和 sync 持久化模式，以及进程重启后的 WAL 恢复。
- 支持运行时原子更新 AK/SK/STS 凭证和发送目标。
- 支持 Swift Package Manager 和 CocoaPods，最低系统版本为 iOS 13、Intel Mac 的
  macOS 10.15，以及 Apple Silicon Mac 的 macOS 11.0。
- 随 SDK 提供 Privacy Manifest 和 Swift 示例 App。
- 原生支持 macOS arm64 和 x86_64；macOS 默认关闭 iOS 生命周期处理，默认
  `metadata.source` 为 `"macOS"`。

### Behavior

- 日志组 metadata 支持空 `source`、空或省略的 `fileName`，以及空 tags。
- Producer 采用 at-least-once 交付语义；重试、恢复或响应丢失可能产生重复日志。
- `add` 成功只表示日志达到所选模式的本地接收边界，不表示服务端已经接收。
- `close` 成功表示本地发送线程已安全停止，不表示全部日志已经远端送达。
- HashKey 使用 32 位小写十六进制半开区间
  `[00000000000000000000000000000000, ffffffffffffffffffffffffffffffff)`。
- 时间戳保留 Unix epoch 毫秒及该毫秒之后的纳秒余数。
- `region`、`projectID` 和 `topicID` 拒绝首尾空白，避免配置在服务端才延迟失败。
- 单批原始日志数据最大可配置为 9.5 MiB，为服务端 10 MB 请求上限预留协议开销。
- iOS 自动生命周期处理仅提供尽力而为的封批与唤醒；正常、可控退出应显式调用
  `close(timeout:)`，异常终止后的恢复依赖持久化模式。

### Security and reliability

- 基于 C SDK v0.3.2，包含持久化、内存分配失败和队列恢复修复。
- endpoint 只接受 HTTPS origin，并拒绝不安全的 redirect。
- 默认不记录凭证、Authorization、请求体或响应体。
- 持久化文件位于 Application Support 并排除备份；iOS 额外使用 Data Protection。
- 内存分配、存储和发送失败通过同步错误或批次回调报告；未确认的持久化数据可在后续恢复。
- 持久化写入抛错后仍可能在恢复时发送，详见[持久化与恢复](docs/guides/persistence-and-recovery.md)。

### Compatibility

- Producer 使用 `v2.0.x` 主线；原有 TLS iOS SDK 继续使用 `v1.x` 兼容路线，旧版入口与
  `legacy/1.x` 维护分支说明见[迁移文档](docs/migration/v1-to-v2.md)。
- Producer v2 只提供日志上传能力，不提供查询、消费或管理接口。
