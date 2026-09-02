# VolcengineTLSProducer — 实施决策索引

> 本文件记录当前冻结合同。需求与优先级冲突时，以 workspace 侧
> [Implementation Decision Ledger](../../docs/research/tls-ios-producer-sdk-implementation-decision-ledger.md)
> 为准；执行证据以最新 acceptance report 为准。

## 当前状态（2026-09-02）

- Development Preview / release candidate source，**不是 Beta/GA**。
- Public `Producer.open` 只使用 Real C Core，不存在无 destination 时静默降级为
  内存实现。
- Xcode 26.6 Simulator、严格 Swift 6、SwiftPM consumer、CocoaPods lint/consumer、
  最终源码 BOE AK/SK/STS、通用真机生命周期、本地 HTTPS redirect、sanitizer、
  进程级 recovery 与 pinned SLS `4.3.4` x86_64 共存链接已有证据。当前早期 BOE
  AK/SK env 未强制成功响应必须
  含 requestID，因此 requestID 贯通只引用独立 wire/合同测试。
- 精确 `6d3747e` 已通过 Intel Ventura 13.7.8 / Xcode 14.3.1 / Swift 5.8.1、
  CocoaPods/SwiftPM 外部消费者、真实 BOE STS 与通用真机生命周期验收。SDK 自身
  隐私边界与打包资源已冻结；业务 App 的数据分类、签名和 App Store Connect 流程
  属于集成方责任。SDK 发布仅待远端 tag 与 owner sign-off。精确 iOS 13 真机不可得，
  不再单独作为阻断项。
- product source 等同 exact `ef1b69e` 的真机 protection audit 已证明五类 Core
  文件均为 `CompleteUntilFirstUserAuthentication` + no-backup；30 分钟线上
  Instruments/135,000 条 Search+Consume 已补齐 CPU/RSS/thermal、WAL 有界回收和
  端到端一致性。USB 供电下不声明真实电池续航。

## 冻结公共语义

1. Producer-only、Swift-first；ObjC public facade、contextFlow、自动 STS
   Provider、XCFramework 不进入当前 P0。
2. 最低 deployment target = iOS 13.0；manifest 使用 Swift tools 5.8。
   最低版本证据由 SwiftPM/Pod 声明一致性、iOS 13 generic-device 与 arm64/x86_64
   Simulator compile、外部 consumer link、最终 iPhoneOS Mach-O
   `platform IOS / minos 13.0` 共同组成；Xcode 26 的 Simulator linker 会将最终
   Simulator Mach-O 下限钳制到 14.0，该产物不承担 iOS 13 设备最低版本证明。
   更新系统的 arm64/x86_64 Simulator 负责运行行为。缺少精确 iOS 13 真机不推导
   为兼容通过，也不再作为发布 blocker。
   该策略参考 SLS 的兼容方法而不照抄其版本值：SLS 用不同 Swift tools manifest
   表达平台下限，并对高版本系统 API 使用 `#available` / `@available`；本 SDK
   保持单一 iOS 13 合同，并由消费者编译与产物门禁防止无意抬高最低版本。
3. P0 公共方法只有 `open / add(mode:) / updateCredentials /
   updateDestination / close`。
4. Public `open` 必须携带并重新校验完整 destination、configuration 和
   credentials；输入在 open 边界防御性复制。Core 构造、WAL recovery 和 close
   不在调用方 MainActor 上执行。
5. `.normal` 进入批量窗口；`.immediate` 封批并唤醒 sender；两者都不等待网络
   或服务端 ACK。
   `LogEvent.hashKey` 为 `nil`，或位于半开区间
   `[00000000000000000000000000000000, ffffffffffffffffffffffffffffffff)`
   的精确 32 位小写十六进制；全 `f` 是排除的上界，与 SLS 路由合同一致。
   `LogEvent.timestamp` 在线路上拆成 Unix epoch 毫秒 `Time` 与该毫秒之后的
   `TimeNs` 余数 `0..<1_000_000`；余数为 0 时省略 optional 字段。该合同保留
   Foundation `Date` 可表达的亚毫秒精度，不把设备时钟分辨率宣传为真实纳秒级。
6. `updateCredentials` 原子替换 AK/SK/STS 整组；`updateDestination` 使用
   current-target 语义，已接收 backlog 可能改投新 endpoint/region/topic。
   v0.3.1 update API 没有 projectID 参数，所以 projectID 只更新 SDK snapshot，
   不改变 wire target。projectID 是未来 project 域名路由的预留字段；当前只做
   non-empty、NUL、CR/LF 最小安全校验，不猜测长度或字符集。
7. `close(timeout:)` 成功只表示本地 worker/session 安全停止和本地持久化收尾；
   不表示全部远端送达。失败向调用方抛错并允许重试，同一 attempt 的并发 waiter
   获得同一结果。
8. 同一 live Producer 内，每个已封批最多只有一个终态 `SendResult`。persistent
   retry cycle 耗尽不是终态；Core 保留 WAL/task 并自动延迟重试。local close 把
   retry-delayed batch 留给下次 recovery，不向旧 handler 伪造终态。稳定字段为
   `status/rawBytes/compressedBytes/requestID/error`；HTTP、transport、auth、
   quota、persistence、timeout 映射为稳定 `ProducerError`。
9. `.disabled` / `.memory` 不创建 WAL；`.buffered` / `.sync` 必须提供合法
   `producerID`，并满足 container、no-backup 与 Data Protection 约束。
10. buffer `.reject` 忽略 blockTimeout；`.block` 使用 bounded blockTimeout。
11. 调用方必须 retain Producer 直到 `close` 完成。未 close 就释放时，SDK 只
    保证异步 destroy 不阻塞释放线程并避免 UAF；尚未交付的 callback 可能丢弃。
12. 交付模型保持 at-least-once：请求可因 retry/recovery/ACK 丢失而重放，重复日志
    由业务接受，SDK 不做跨请求去重。`.buffered` / `.sync` 只对已达到 WAL durability
    且存储完整、非 drop 策略的数据提供恢复重试；memory/disabled 进程死亡、WAL
    丢失/损坏、admission 拒绝及策略明确丢弃不在承诺内。不承诺 exactly-once，也
    不承诺 App 被强杀后继续实时上传。
13. batch 默认仍为 1 MiB；public initializer/open 与 ObjC Bridge 的可配置上限为
    9.5 MiB（9,961,472 bytes），并写入 Core 的 package 与 aggregate raw-byte
    两个限制，在服务端 10 MiB 绝对上限下保留 framing 余量。
14. 默认性能验收口径为 1 KiB/10 fields/LZ4/1 sender，100/300 logs/s 两档，
    memory/persistent 分组，pinned SLS 稳定 tag `4.3.4` 同机 Release A/B；每组
    warm-up 5 分钟、测量 30 分钟、至少 3 次。P99 add latency、CPU、RSS 任一相对
    SLS 恶化超过 20% 即失败，且 admission/terminal loss 必须为零。1 log/s soak
    只验稳定性与 RSS 趋势，不是吞吐门禁。

## 安全与传输

- endpoint 只能是 HTTPS origin：必须有 host，显式 port 必须在 1…65535，不允许
  userinfo、path、query 或 fragment。
- URLSession 使用调用方 configuration 的防御性副本；禁用 cache、cookie、
  credential store。
- redirect 仅允许 normalized origin（scheme/host/effective port）以及签名覆盖的
  method/path/query/body 全部不变；其余 redirect 是不可重试终态，Authorization
  不会被转发。V4 将 Host（含显式 port）加入 canonical headers，跨端口直接复用
  Authorization 会改变签名目标且可能把凭证发送给同 host 的另一服务；当前不放宽。
  后续支持必须由 Core 对 redirect 目标重新签名并加端口 allowlist。
- TLS challenge 使用系统默认信任；无 trust-all、证书 pinning 绕过或调试开关。
- SDK 不直接记录 credentials、Authorization 或原始请求/响应 body；C string
  边界拒绝 embedded NUL 和 CR/LF。`securityToken=nil` 在整组凭证更新时表示
  显式清除旧 token。服务端 `requestID` 在截断为 256 个字符并收敛到
  `[A-Za-z0-9._:-]` 字符集后进入公开结果/错误；SDK 日志只记录稳定指纹，不记录
  文本。endpoint 仍必须属于可信服务边界，恶意服务端反射不在绝对零泄漏承诺内。
- TLS 官方响应头为 `x-tls-requestid`；transport 与 Core bridge 同时兼容已有的
  `x-tls-request-id` 拼写，二者均按大小写不敏感提取。
- transport 响应体上限为 64 KiB；超限返回不可重试的稳定错误，不向 Core
  交付部分 body。
- SDK redacting logger 默认关闭；只有 Bridge 内部显式 opt-in 才调用 `NSLog`。
  该开关不是 public API；未来若需消费者控制，使用可注入日志门面，不改变 Release
  默认关闭合同。
- 同一 persistent directory 由 `.ios-producer.lock` + `flock` 排除第二个活跃
  Bridge adapter；lock/lease 不跟随符号链接，失败按 persistence error 返回。
- Core POSIX file-open 在平台支持时使用 `O_NOFOLLOW | O_CLOEXEC`，拒绝
  manifest/checkpoint/segment 的 final-component symlink。
- 该 `flock` 只约束遵守 iOS Bridge 协议的实例，不能约束直接绕过 Bridge 的其他
  Core 实现。
- persistent 默认固定为 256 MiB / 20 万条 / 32 个 8 MiB segment，overflow
  reject-new，且没有 public 调整项。WAL 依赖系统 Data Protection，不提供 SDK
  应用层加密。

## 工程与分发边界

- `VolcengineTLSProducer` 是唯一受支持 SwiftPM product；`CoreAdapter` 是 internal。
- SwiftPM 将 C Core + Objective-C Bridge 合并为一个 `TLSProducerBridge` Clang
  target，使 final consumer Mach-O 中 `ve_tls_*` / LZ4 实现符号保持 hidden。
- `TLSProducerBridge` 不是 product，也不由 public Swift module re-export；但
  SwiftPM 不对传递 target module 强制访问控制，源码 consumer 仍可直接 import。
  这种导入是 unsupported implementation detail，不享有源码/ABI 兼容承诺。
- CocoaPods 把 Bridge headers 放在 PrivateHeaders，public headers 为空；外部 Pod
  consumer 不能 import `TLSProducerBridge`。默认 static library 与 static
  framework 两种 `:path` consumer 都必须通过。
- CocoaPods 当前用 `@_implementationOnly` 引入私有 Clang module，但未开启
  `BUILD_LIBRARY_FOR_DISTRIBUTION`；接受源码分发 warning，不宣称 binary ABI
  stability。
- Producer 使用 `v2.0.x` 版本线，首个候选为 `v2.0.0`；`v1.x` 保留给旧 SDK
  更新。远端 `v2.0.0` tag 创建/推送必须发生在发布 owner 接受全部门禁之后。

## Core 衍生关系

- upstream 基线：C Core v0.3.1，commit
  `08f33affc2f346f92dc0734cbb92330dd272156c`。
- 当前 vendored Core 不是字节级未修改上游包；包含 iOS 集成补丁：custom
  transport 尊重 `transport_retryable`、auth retain 单终态、persistent 跨 cycle
  delayed retry、destroy/stop 有界释放、POSIX no-follow，以及 package-internal /
  LZ4 hidden visibility。
- Core 行为与 POSIX 补丁从 `origin/persistent@c7fa2fa` 之上的本地提交
  `613b38d` 起整理；加入 admission、精确线程数、sealed-batch ownership transfer
  与 key aggregate 生命周期修复后的当前 feature tip 为 `62241b5`，仍未
  push/merge/tag，不能写成已发布上游版本。
- Bridge 另补齐 effective `retry_policy.max_attempts`、NSURLSession transport、
  structured error、persistent directory lock 和 autorelease pool；retryable
  persistent batch 在有界 cycle 后进入最长 5 分钟的 jittered delayed retry。
- `CORE_VERSION` 中的 source bundle SHA 只证明 upstream 输入包，不证明集成后
  工作树与上游完全一致。

## 隐私决策

- `stat(2)`/文件元数据使用声明
  `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1`。
- SDK 不自动采集用户、设备、崩溃、性能或使用行为数据，只处理调用方显式提供的
  日志，因此 SDK manifest 的 `NSPrivacyCollectedDataTypes=[]` 是正式的 SDK 自身
  边界。它不表示调用方日志不会离开设备。
- 业务 App 必须按实际日志内容与用途声明 data type、linkage、tracking 和 purpose，
  并负责自身签名、App Store Connect 和 App Review。SDK 负责确保同一 manifest 在
  SwiftPM/CocoaPods 产物中可见，并提供 `PRIVACY.md` 接入说明。

## 模拟器稳定性证据

- 正式 2h Simulator soak v11 已通过：6908 accepted / observed / success、0
  failure、单 PID；RSS 覆盖率 96.81%、最大间隔 2 秒、首尾 5 分钟中位数下降
  2528 KiB、完整窗口斜率 -552.40 KiB/h；但它早于官方 requestID 响应头修复，
  只作为修复前稳定性证据。v12 因 Release 逐请求日志默认开启主动中止；v13 因
  delayed retry destroy 等待问题主动中止。精确提交 `19b8648` 的最终 v1 已完整
  通过：6920 accepted / observed / success、0 failure；RSS 覆盖率 96.42%、最大
  间隔 2 秒、首尾 5 分钟中位数下降 15968 KiB、斜率 -6175.36 KiB/h。
- 最终 exact `6a347f8` 的 Intel x86_64 顺序交换代表性性能矩阵 8/8 通过；
  memory add/CPU/peak RSS `0.581/1.005/0.692`，persistent
  `0.914/1.085/0.698`。按最终验收决定，不再重复完整 24-case 或 14 小时矩阵；
  SLS 4.3.4 close 仍按已知 UAF 边界未验证。

## 仍未完成的发布动作

- 远端 `v2.0.0` tag、发布说明、publish 授权与最终 owner sign-off。
