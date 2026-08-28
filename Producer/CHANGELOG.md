# Changelog

All notable changes to VolcengineTLSProducer are documented here. Development
Preview 阶段不承诺 Semantic Versioning 兼容性。

## 0.0.2 — Development Preview (unreleased, 2026-08-28)

### Added

- 集成 upstream C Core v0.3.1 基线（commit
  `08f33affc2f346f92dc0734cbb92330dd272156c`）：WAL/recovery、retry、LZ4、
  V4 signing、批处理与并发 sender。
- `RealCoreAdapter` + `TLSRealCoreAdapter`：Swift/ObjC/C 生命周期、per-instance
  URLSession transport、结构化错误和终态 callback。
- Public destination-at-open、持久化模式、bounded buffer block timeout、
  automatic lifecycle handling。
- Simulator Recovery Harness、进程强杀 recovery、long-running soak/RSS sampler、
  本地真实 HTTPS redirect fixture 与 opt-in BOE 测试。
- SwiftPM/CocoaPods 外部 consumer、Privacy resource 与 final Mach-O symbol gates。

### Fixed

- Public `open` 强制验证 HTTPS origin、完整配置和凭证，并在 utility executor
  构造/recover Core；配置突变在 open 边界重新验证并复制。
- 修复 HTTP timeout 丢失、response allocator 泄漏、URLSession 配置旁路、错误
  原文泄漏、timeout/cancel 竞态与 late callback/context 生命周期。
- 未 close 就释放 adapter 时，Core destroy 转移到 utility queue 并保活 raw
  callback/HTTP context；该路径只保证安全清理，不承诺剩余 callback。
- redirect 收紧为 normalized origin + 完整 signed target 不变；拒绝跨 host、
  scheme、port 或 method/path/query/body 变化，且不重试/不转发 Authorization。
- close 传播 timeout/error，同一 attempt waiter 同结果；失败保持不可 admission
  但允许后续 close retry；成功后幂等。
- 正确传递 persistence、buffer policy、sendConcurrency、effective
  `retry_policy.max_attempts`、lifecycle 和 structured public error。
- persistent 目录 fail-fast；Core 文件应用 no-backup/Data Protection；Bridge
  process lock 拒绝第二活实例、symlink lock 和异常 lease，crash 后可立即 reopen。
- POSIX Core file-open 使用 `O_NOFOLLOW | O_CLOEXEC`（平台可用时），拒绝预置
  manifest/checkpoint/segment symlink，避免读写或截断其 target。
- 配置数值做 finite/whole-millisecond/Int32 校验；拒绝空 event、embedded NUL、
  危险 producerID、越界 timestamp 和非法 post-init mutation。
- Core raw pthread 的 file/HTTP/send callback 加局部 `@autoreleasepool`，消除
  长时发送的 Foundation autorelease 累积。
- custom transport 的 `transport_retryable` 不再被 Core 强制覆盖；401/403、429、
  5xx、timeout、redirect 具有受测的重试/终态语义。
- persistent `unauthorizedPolicy.retain` 不再先回调失败、凭证更新后又回调成功；
  retained auth failure 只记 metrics，恢复发送后只产生一个终态 `SendResult`。
- persistent retryable 失败耗尽单轮预算后不再发布假终态或搁置到重启；live
  Producer 将同一 task 放回 keyed delayed queue，带 jitter 指数退避（上限 5
  分钟）后继续发送。local close 保留 WAL 给下一次 recovery，仍是有界本地停止。
- Swift 6 strict concurrency、SwiftPM 单 Clang target 链接、C/LZ4 hidden
  visibility、第三方 LZ4 notice 与 Privacy FileTimestamp/C617.1 声明。
- 服务端 requestID 在 transport 边界截断/规范化；SDK 诊断日志只记录稳定指纹，
  不再把服务端文本原样交给 `NSLog`。redirect 方法名按 HTTP/V4 合同大小写精确比较。
- requestID 响应头修正为 TLS 官方 `x-tls-requestid`，并保留原
  `x-tls-request-id` 的大小写不敏感兼容；最终 BOE public requestID 断言通过。
- 凭证整组更新时，`securityToken=nil` 会显式清除旧 STS token；Swift 与 ObjC
  边界拒绝 header-bound 字段中的 CR/LF，避免换行注入且错误不回显输入。
- transport 将响应体限制为 64 KiB；超限在追加前终止、清空部分 body、标记为
  不可重试，避免恶意或误配 endpoint 导致无界内存增长。
- `LogEvent.hashKey` 在 public/Bridge 两层统一为精确 32 位小写十六进制；batch
  可配置上限收紧为 9.5 MiB（9,961,472 bytes），同时写入 Core package/aggregate
  raw-byte 限制，在服务端 10 MiB 绝对上限下保留 framing 余量。
- 冻结 at-least-once 边界：retry/recovery 可产生重复；只有已持久化且存储完整、
  非 drop 策略的数据进入恢复重试，不把 local close 描述为远端 ACK。

### Verified distribution status

- Xcode 26.6：iOS 26.5 / 26.3.1 arm64 Simulator 全量 250 total，244 passed，
  0 failed，6 opt-in skipped；真实 redirect 4/4；最终源码 BOE AK/SK 200 + public
  requestID 与错误 SK `.auth` 2/2。
- ASan/TSan 全量均为 244 passed / 0 failed / 6 skipped。
- SwiftPM strict Swift 6、iOS 13 deployment：arm64/x86_64 × Debug/Release 产品
  build；外部 public lifecycle/resource/symbol consumer 通过。
- CocoaPods 1.17.0 完整 `pod lib lint`、默认 static library consumer、static
  framework consumer、私有 header/module 与 final symbols/resources 通过。
- 100 轮历史进程恢复 + 最终 Release 通用 Harness 3 buffered / 3 sync、60/60
  recovered 回归通过。
- persistent retry-cycle live recovery 与 persisted-for-recovery close/reopen 定向
  2/2 通过；v6/v7/v8/v9 分别因 requestID 日志、旧 STS token 未清除、无界响应
  体、未限制 sender 线程/移动端 buffer 资源包络而主动中止。v10 因最新 hashKey、
  9.5 MiB、projectID 与 at-least-once 合同改变而主动中止。最终 v11 完整 7200 秒
  通过：6908 accepted / observed / success、0 failure、单 PID；RSS 覆盖率
  96.81%、最大间隔 2 秒、中位数增长 -2528 KiB、斜率 -552.40 KiB/h；但它早于
  官方 requestID 响应头修复，最终 v12 尚未完成。

### Release blockers

- Xcode 14.3.1 / Swift 5.8、iOS 13 真机、STS、真机 Instruments/background/
  Data Protection、隐私数据分类/App Store privacy report 尚未完成。
- 最终 2h Simulator soak v12 尚未完成。
- 远端 `0.0.2` tag 尚未创建。
- 当前仍是 Development Preview / release candidate source，不可标记 Beta/GA。

## 0.0.1 — Development Preview (2026-08-27)

- 初始 Swift-first P0 API、值模型、Fake/Bundled test seam、Bridge/Transport/
  Persistence 测试骨架和示例。
- 当时没有 Real Core 或 Apple 工具链执行证据；该历史状态已由 0.0.2 的实现和
  最新 acceptance report 取代。
