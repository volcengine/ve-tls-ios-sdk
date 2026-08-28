# VolcengineTLSProducer — 实施决策索引

> 本文件记录当前冻结合同。需求与优先级冲突时，以 workspace 侧
> [Implementation Decision Ledger](../../docs/research/tls-ios-producer-sdk-implementation-decision-ledger.md)
> 为准；执行证据以最新 acceptance report 为准。

## 当前状态（2026-08-28）

- Development Preview / release candidate source，**不是 Beta/GA**。
- Public `Producer.open` 只使用 Real C Core，不存在无 destination 时静默降级为
  内存实现。
- Xcode 26.6 Simulator、严格 Swift 6、SwiftPM consumer、CocoaPods lint/consumer、
  BOE AK/SK、本地 HTTPS redirect、sanitizer 与进程级 recovery 已有证据；BOE
  最终源码精确复跑仍需凭证使用授权。
- Xcode 14.3.1、iOS 13 真机、STS、隐私数据分类/App Store report 和远端 tag
  仍是发布阻断。

## 冻结公共语义

1. Producer-only、Swift-first；ObjC public facade、contextFlow、自动 STS
   Provider、XCFramework 不进入当前 P0。
2. 最低 deployment target = iOS 13.0；manifest 使用 Swift tools 5.8。
3. P0 公共方法只有 `open / add(mode:) / updateCredentials /
   updateDestination / close`。
4. Public `open` 必须携带并重新校验完整 destination、configuration 和
   credentials；输入在 open 边界防御性复制。Core 构造、WAL recovery 和 close
   不在调用方 MainActor 上执行。
5. `.normal` 进入批量窗口；`.immediate` 封批并唤醒 sender；两者都不等待网络
   或服务端 ACK。
6. `updateCredentials` 原子替换 AK/SK/STS 整组；`updateDestination` 使用
   current-target 语义，已接收 backlog 可能改投新 endpoint/region/topic。
   v0.3.1 update API 没有 projectID 参数，所以 projectID 只更新 SDK snapshot，
   不改变 wire target。
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
12. 不承诺 exactly-once，也不承诺 App 被强杀后继续实时上传。

## 安全与传输

- endpoint 只能是 HTTPS origin：必须有 host，显式 port 必须在 1…65535，不允许
  userinfo、path、query 或 fragment。
- URLSession 使用调用方 configuration 的防御性副本；禁用 cache、cookie、
  credential store。
- redirect 仅允许 normalized origin（scheme/host/effective port）以及签名覆盖的
  method/path/query/body 全部不变；其余 redirect 是不可重试终态，Authorization
  不会被转发。
- TLS challenge 使用系统默认信任；无 trust-all、证书 pinning 绕过或调试开关。
- SDK 不直接记录 credentials、Authorization 或原始请求/响应 body；C string
  边界拒绝 embedded NUL 和 CR/LF。`securityToken=nil` 在整组凭证更新时表示
  显式清除旧 token。服务端 `requestID` 在截断为 256 个字符并收敛到
  `[A-Za-z0-9._:-]` 字符集后进入公开结果/错误；SDK 日志只记录稳定指纹，不记录
  文本。endpoint 仍必须属于可信服务边界，恶意服务端反射不在绝对零泄漏承诺内。
- transport 响应体上限为 64 KiB；超限返回不可重试的稳定错误，不向 Core
  交付部分 body。
- SDK redacting logger 当前每个请求调用 `NSLog`；字段安全不等于生产默认合适，
  Beta 前应决定默认关闭或可注入日志门面。
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
- 远端 `0.0.2` tag 创建/推送必须发生在发布 owner 接受全部门禁之后。

## Core 衍生关系

- upstream 基线：C Core v0.3.1，commit
  `08f33affc2f346f92dc0734cbb92330dd272156c`。
- 当前 vendored Core 不是字节级未修改上游包；包含 iOS 集成补丁：custom
  transport 尊重 `transport_retryable`、package-internal visibility 与 LZ4 hidden
  visibility。
- Bridge 另补齐 effective `retry_policy.max_attempts`、NSURLSession transport、
  structured error、persistent directory lock 和 autorelease pool；retryable
  persistent batch 在有界 cycle 后进入最长 5 分钟的 jittered delayed retry。
- `CORE_VERSION` 中的 source bundle SHA 只证明 upstream 输入包，不证明集成后
  工作树与上游完全一致。

## 隐私决策

- `stat(2)`/文件元数据使用声明
  `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1`。
- `NSPrivacyCollectedDataTypes=[]` 只是 development placeholder。SDK 会传输并可
  持久化调用方日志，不能据此宣称“不收集数据”。
- Beta 前必须由产品/隐私/法务确认 collected data type、linkage、tracking 和
  purpose，并验证 SwiftPM/CocoaPods archive 生成的 privacy report 与 App Store
  Connect 结果。

## 仍未完成的发布门禁

- Xcode 14.3.1 / Swift 5.8 runner；iOS 13 真机。
- 真机 background/Data Protection/Instruments；STS 临时凭证。
- 正式 2h Simulator soak v10 的最终功能与 RSS 结果（尚未完成；v6/v7/v8/v9
  分别因 requestID 日志、旧 STS token 残留、无界响应体和资源配置上限缺失而
  主动中止）。
- 隐私数据分类、archive privacy report、App Store Connect 校验。
- 远端 tag、发布说明、最终 owner sign-off。
