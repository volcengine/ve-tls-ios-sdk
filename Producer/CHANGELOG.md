# Changelog

All notable changes to VolcengineTLSProducer are documented here. Development
Preview 阶段不承诺 Semantic Versioning 兼容性。

## 0.0.2 — Development Preview (unreleased, 2026-08-28)

### Added

- 集成 upstream C Core v0.3.1 基线（commit
  `08f33affc2f346f92dc0734cbb92330dd272156c`）：WAL/recovery、retry、LZ4、
  V4 signing、批处理与并发 sender。当前交付是该基线加可审计 iOS patchset，
  不是未修改的上游包；patch commits 与 diff checksum 见 `CORE_VERSION`。
- 修复 persistent 批次处于跨轮退避时直接 destroy 只置 `stop`、sender 仅检查
  `closing` 导致 worker join 等待延迟计时器的问题；内存任务释放，WAL 保持未 ACK
  供下次 recover。该修复最初落在 C Core `persistent` 本地提交 `613b38d`；当前
  包含后续 admission、精确线程数、sealed-batch ownership transfer 与 key
  aggregate 生命周期修复的本地 feature tip 为 `62241b5`，尚未推送。
- `RealCoreAdapter` + `TLSRealCoreAdapter`：Swift/ObjC/C 生命周期、per-instance
  URLSession transport、结构化错误和终态 callback。
- Public destination-at-open、持久化模式、bounded buffer block timeout、
  automatic lifecycle handling。
- Simulator Recovery Harness、进程强杀 recovery、long-running soak/RSS sampler、
  本地真实 HTTPS redirect fixture 与 opt-in BOE 测试。
- SwiftPM/CocoaPods 外部 consumer、Privacy resource 与 final Mach-O symbol gates。

### Fixed

- 修复 persistent direct-merge 与 sender completion 的 key-queue 生命周期竞态：
  前一批仍 in-flight 时新日志已进入 aggregate builder，旧逻辑只检查 sealed task
  count 并释放整个 key queue，造成日志 ID 空洞、ACK 前缀/WAL 回收停滞，最终在
  200,000 records 后拒绝新日志。C Core `62241b5` 与 iOS `ca1a9c8` 增加非空
  builder 保护；缩放 C 回归、Release/ASan+UBSan 13/13、arm64 Simulator 261 项及
  220,000 条 persistent 容量回归通过。exact `bcf7bd7` 的 24 组短矩阵也已通过，
  四组 add P99/CPU/RSS 均 `≤1.20×`；正式 5 分钟 warm-up + 30 分钟测量仍待重跑。
- Public `open` 强制验证 HTTPS origin、完整配置和凭证，并在 utility executor
  构造/recover Core；配置突变在 open 边界重新验证并复制。
- 修复 HTTP timeout 丢失、response allocator 泄漏、URLSession 配置旁路、错误
  原文泄漏、timeout/cancel 竞态与 late callback/context 生命周期。
- sealed batch 直接把 builder allocation 转移给 send task，避免约 1 MiB 批次在
  wire framing 时再分配并复制第二份 buffer；snapshot/export 仍保留复制语义，
  realloc/metadata 分配失败保持 builder 原状。
- 未 close 就释放 adapter 时，Core destroy 转移到 utility queue 并保活 raw
  callback/HTTP context；该路径只保证安全清理，不承诺剩余 callback。
- redirect 收紧为 normalized origin + 完整 signed target 不变；拒绝跨 host、
  scheme、port 或 method/path/query/body 变化，且不重试/不转发 Authorization。
- close 传播 timeout/error，同一 attempt waiter 同结果；失败保持不可 admission
  但允许后续 close retry；成功后幂等。
- 正确传递 persistence、buffer policy、sendConcurrency、effective
  `retry_policy.max_attempts`、lifecycle 和 structured public error。
- 修复 Core 将显式 send/pack thread count `1` 与 runtime auto 默认混淆、在 64 MiB
  buffer 下实际展开成 `2+2` 线程的问题；0 代表 auto，正整数均为精确值。
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
  `x-tls-request-id` 的大小写不敏感兼容；wire/合同测试覆盖 public requestID。
- 凭证整组更新时，`securityToken=nil` 会显式清除旧 STS token；Swift 与 ObjC
  边界拒绝 header-bound 字段中的 CR/LF，避免换行注入且错误不回显输入。
- transport 将响应体限制为 64 KiB；超限在追加前终止、清空部分 body、标记为
  不可重试，避免恶意或误配 endpoint 导致无界内存增长。
- `LogEvent.hashKey` 在 public/Bridge 两层统一为精确 32 位小写十六进制；batch
  可配置上限收紧为 9.5 MiB（9,961,472 bytes），同时写入 Core package/aggregate
  raw-byte 限制，在服务端 10 MiB 绝对上限下保留 framing 余量。
- 冻结 at-least-once 边界：retry/recovery 可产生重复；只有已持久化且存储完整、
  非 drop 策略的数据进入恢复重试，不把 local close 描述为远端 ACK。
- 逐请求 transport `NSLog` 改为默认关闭；Bridge 内部诊断必须显式 opt-in，避免
  Release 高频日志与无条件格式化开销。

### Verified distribution status

- Xcode 26.6：iOS 26.5 / 26.3.1 arm64 Simulator 全量 252 total，246 passed，
  0 failed，6 opt-in skipped；真实 redirect 4/4；最终源码 BOE AK/SK 200 与错误
  SK `.auth` 2/2。该 BOE env 未要求成功响应必须含 requestID，不能据此过度声明。
- ASan/TSan 全量均为 246 passed / 0 failed / 6 skipped。
- SwiftPM strict Swift 6、iOS 13 deployment：arm64/x86_64 × Debug/Release 产品
  build；generic iPhoneOS arm64、外部 public lifecycle/resource/symbol consumer
  与最终 iPhoneOS Mach-O `platform IOS / minos 13.0` 纳入综合门禁。Xcode 26.6
  生成的 Simulator 最终 Mach-O 为 `minos 14.0`，不作为设备最低版本证据。
- 精确提交 `bac7b22` 在 Intel Xcode 16.4 / iOS 18.5 x86_64 Simulator 全量
  261 total：255 passed、0 failed、6 opt-in skipped；5 个测试 bundle 均为
  x86_64。
- CocoaPods 1.17.0 完整 `pod lib lint`、默认 static library consumer、static
  framework consumer、私有 header/module 与 final symbols/resources 通过；TLS 与
  pinned SLS `4.3.4` 的 x86_64 混编 consumer 同 App 链接通过；临时覆盖 SLS
  podspec 的 arm64 Simulator 排除后，arm64 Release 编译、安装与启动通过，但不
  计作官方原样 Pod 支持证据。
- 100 轮历史进程恢复 + 最终 Release 通用 Harness 3 buffered / 3 sync、60/60
  recovered 回归通过。
- persistent retry-cycle live recovery 与 persisted-for-recovery close/reopen 定向
  2/2 通过；v6/v7/v8/v9 分别因 requestID 日志、旧 STS token 未清除、无界响应
  体、未限制 sender 线程/移动端 buffer 资源包络而主动中止。v10 因最新 hashKey、
  9.5 MiB、projectID 与 at-least-once 合同改变而主动中止。最终 v11 完整 7200 秒
  通过：6908 accepted / observed / success、0 failure、单 PID；RSS 覆盖率
  96.81%、最大间隔 2 秒、中位数增长 -2528 KiB、斜率 -552.40 KiB/h；但它早于
  官方 requestID 响应头修复。v12 因随后发现 Release 逐请求日志仍默认开启而主动
  中止；v13 因 delayed retry destroy 等待问题主动中止。精确 `19b8648` 的最终
  v1 完整 7200 秒通过：6920 accepted / observed / success、0 failure、单 PID；
  RSS 覆盖率 96.42%、最大间隔 2 秒、首尾 5 分钟中位数下降 15968 KiB、斜率
  -6175.36 KiB/h。

### Release blockers

- Xcode 14.3.1 / Swift 5.8、STS、通用真机 Instruments/background/Data
  Protection、隐私数据分类/App Store privacy report 尚未完成。精确 iOS 13 真机
  不再是 blocker；最低版本由声明、compile/link 与 Mach-O minos 门禁证明。
- 性能口径已冻结为 1 KiB/10 fields/LZ4/1 sender、100/300 logs/s、
  memory/persistent 分组、pinned SLS `4.3.4` 同机 Release A/B；P99 add latency、
  CPU、RSS 相对恶化不得超过 20%。SLS 原 podspec 排除 arm64 Simulator；临时
  source-build override 在 admission 优化后的 clean 24 组中，memory 100/300 与
  persistent 100 全过，persistent 300 的 add P99 `1.002×`、RSS `1.118×` 通过，
  CPU `1.272×` 失败。线程 auto/explicit 冲突修复后，该组 6 轮定向复测为 CPU
  `1.083×`、add P99 `0.762×`、RSS `1.114×` 全过。随后 memory 300 的 Intel
  定向证据 RSS `1.242×` 失败；sealed-batch ownership transfer 后，精确
  `2ed85f0` arm64 同合同 6 轮 CPU `1.158×`、add P99 `0.559×`、RSS `1.119×`
  全过。前后硬件不同，只使用各自同机 TLS/SLS 比值，不横比绝对 RSS。独立 Linux 开发机固定
  vCPU/NUMA 的 C persistent 复测确认 task 数 6→4，250/1000 logs/s 的
  user-space task-clock 中位数分别下降 12.08%/13.30%。`cd094d8` 正式 24 组因
  persistent 200,000-record 正确性错误失败；该错误已在 C Core `62241b5` / iOS
  `ca1a9c8` 修复并通过 220,000 条容量回归；exact `bcf7bd7` 的 24 组短矩阵随后
  全绿，但仍需重跑正式 5 分钟 warm-up + 30 分钟测量矩阵。
  Intel 功能全量通过也不能替代正式性能矩阵。
- 远端 `0.0.2` tag 尚未创建。
- 当前仍是 Development Preview / release candidate source，不可标记 Beta/GA。

## 0.0.1 — Development Preview (2026-08-27)

- 初始 Swift-first P0 API、值模型、Fake/Bundled test seam、Bridge/Transport/
  Persistence 测试骨架和示例。
- 当时没有 Real Core 或 Apple 工具链执行证据；该历史状态已由 0.0.2 的实现和
  最新 acceptance report 取代。
