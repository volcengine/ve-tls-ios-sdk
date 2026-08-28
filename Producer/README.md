# VolcengineTLSProducer

火山引擎日志服务（TLS）iOS Producer SDK，Swift-first，集成 C Core v0.3.1
（WAL/recovery、retry、LZ4、V4 signing、批量与并发发送）。

> **Development Preview / release candidate source，不是 Beta/GA。**
>
> 当前 Xcode 26.6 模拟器、SwiftPM、CocoaPods、本地 HTTPS redirect、BOE AK/SK、
> sanitizer 和进程级 WAL recovery 已有执行证据。发布仍受 Xcode 14.3.1、
> iOS 13 真机、STS、隐私数据分类/App Store 校验和远端版本 tag 阻断。

## 要求

- deployment target：iOS 13.0+
- SwiftPM manifest：Swift tools 5.8
- 已验证工具链：Xcode 26.6 / Swift 6.3.3（Swift 5 与严格 Swift 6）
- 声明但尚未现场验证：Xcode 14.3.1 / Swift 5.8

## 安装

### Swift Package Manager（当前开发分支）

```swift
.package(
    url: "https://github.com/volcengine/ve-tls-ios-sdk.git",
    branch: "producer")
```

只依赖 `VolcengineTLSProducer` product。`TLSProducerBridge` 是实现 target，不是
product 或受支持 API。需要注意：SwiftPM 不对传递 target module 实施访问控制，
源码消费者仍可能写出 `import TLSProducerBridge`；该路径没有源码/ABI 兼容承诺。

### CocoaPods

当前 podspec 的本地 lint、默认 static library consumer 和 static framework
consumer 均已通过。远端 `0.0.2` tag 尚未创建，因此发布前只能使用本地路径：

```ruby
pod 'VolcengineTLSProducer', :path => '/path/to/ve-tls-ios-sdk'
```

SwiftPM 与 CocoaPods 编译同一份 `Producer/Sources/`，不维护双实现。当前是源码分发，
未承诺 binary framework ABI stability；Pod 构建仍有 `@_implementationOnly` 未开启
library evolution 的工具链 warning。

## Quick start

```swift
import VolcengineTLSProducer

let destination = Destination(
    endpoint: "https://tls-cn-beijing.volces.com",
    region: "cn-beijing",
    projectID: "YOUR_PROJECT_ID",
    topicID: "YOUR_TOPIC_ID")

let configuration = try ProducerConfiguration(destination: destination)
let credentials = Credentials(
    accessKeyID: "YOUR_AK",
    accessKeySecret: "YOUR_SK",
    securityToken: nil)

let producer = try await Producer.open(
    configuration: configuration,
    credentials: credentials
) { result in
    // 串行 callback delivery；具体执行上下文由 configuration.callbackQueue 决定。
    // 同一 live Producer 内，每个已封批最多只有一个终态结果。
    print(result.status, result.rawBytes, result.error as Any)
}

let event = LogEvent(contents: [
    "level": .string("info"),
    "message": .string("hello tls"),
])

// 同步本地 admission；不等待网络或服务端 ACK。
try producer.add(event, mode: .normal)
// 立即封批并唤醒 sender；仍是异步发送。
try producer.add(event, mode: .immediate)

// 成功表示本地 worker/session 安全停止，不表示全部远端送达。
try await producer.close(timeout: 5)
```

Public `open` 必须在 configuration 中携带 destination。所有 public mutable fields
都会在 open 边界重新校验并复制；非法配置不会创建 Core、持久化目录或网络请求。

## 公共 API 语义

| API | 合同 |
|---|---|
| `Producer.open(...) async throws` | 校验配置/凭证/destination，在 utility executor 构造并 recover Real Core |
| `add(_:mode:) throws` | 同步本地 admission；成功仅表示达到配置的 durability 边界 |
| `updateCredentials(_:) throws` | AK/SK/STS 整组原子替换 |
| `updateDestination(_:) throws` | 整组替换 current target；endpoint/region/topic 进入 v0.3.1 sender，projectID 保存在 SDK snapshot，预留给未来 project 域名路由 |
| `close(timeout:) async throws` | bounded 本地停止；并发 waiter 同结果；失败可重试；成功后幂等 |

关键默认值：batch 1024 条 / 1 MiB / 3s，buffer 64 MiB `.reject`，
sendConcurrency 1，LZ4，connect 10s，request 15s，maxLogAge 7d。可配置的
`batch.maxRawBytes` 上限为 9.5 MiB（9,961,472 bytes），在服务端 10 MiB 绝对上限
下保留 framing 余量。移动端单实例资源合同还限制 buffer 不超过 256 MiB、
sendConcurrency 不超过 8；initializer 与 open 边界都会重校验，Bridge 也独立
拒绝越界值。`LogEvent.hashKey` 若非 `nil`，必须精确匹配 `[0-9a-f]{32}`。

持久化模式：

- `.disabled` / `.memory`：不创建 WAL，不要求 `producerID`。
- `.buffered` / `.sync`：要求合法 `producerID`，使用 app-container WAL。
- persistent retryable 失败耗尽一轮预算后保留 WAL 与 live task，按带 jitter 的
  指数退避开启下一轮（最长 5 分钟）；不会把中间轮次伪装成终态 failure。
- `close` 遇到 retry-delayed durable batch 时只停止本地 worker 并保留 WAL；旧
  handler 不收到假终态，下一次使用同一 `producerID` open 后继续 recovery。
- 同一 persistent directory 只允许一个遵守 iOS Bridge lock 协议的活跃 adapter。
- 每个 persistent producer 当前固定最多 256 MiB / 20 万条 / 32 个 8 MiB
  segment，超限 reject-new；尚无 public 调整项。
- `.sync` 和 `BufferFullPolicy.block` 可能阻塞调用线程，不应在主线程使用。

交付语义是 **at-least-once，而不是 exactly-once**：网络失败、进程恢复或 ACK
丢失时，同一请求可能被重放，服务端可能看到重复日志，SDK 不提供跨请求去重。
对于 `.buffered` / `.sync`，已完成持久化 admission 的数据会在 WAL 完整、存储仍
可用且 expiry/auth 策略未选择 drop 的前提下恢复并继续重试。该承诺不覆盖
`.disabled` / `.memory` 的进程死亡、调用方删除/损坏 WAL、admission 失败、容量
拒绝或策略明确丢弃的数据；`close` 成功也不等于远端已经 ACK。

## 安全与隐私

- endpoint 必须是纯 HTTPS origin：有 host，显式 port 必须在 1…65535，不允许
  userinfo、path、query、fragment；Core 固定构造 `/PutLogs?TopicId=...`。
- transport 使用调用方 `URLSessionConfiguration` 的防御性副本，禁用 cache、
  cookie 与 credential store。
- redirect 只有在 normalized origin（scheme/host/effective port）以及签名覆盖的
  method/path/query/body 全部不变时才 follow；否则拒绝且不转发 Authorization。
  V4 canonical headers 包含 Host，显式 port 也属于 Host；因此跨端口不能安全复用
  原 Authorization。未来若需支持，必须由 Core 对新目标重新签名并配置允许端口，
  不能只放宽 URLSession delegate。
- SDK 不直接记录 credentials、Authorization 或请求/响应 body；
  `Credentials.description/debugDescription` 固定脱敏；C 字符串拒绝 embedded NUL
  与 CR/LF；凭证整组更新传 `securityToken=nil` 会显式清除旧 STS token。
  服务端 `requestID` 在 256 字符/安全字符集规范化后进入公开结果/错误；SDK 日志
  只记录稳定指纹，不记录 requestID 文本。endpoint 仍必须属于可信服务边界。
- transport 响应体固定上限 64 KiB；超限不返回部分 body，且不会被 Core 重试。
- persistent 文件设置 backup exclusion 与
  `NSFileProtectionCompleteUntilFirstUserAuthentication`；Privacy Manifest 声明
  FileTimestamp / `C617.1`。WAL 没有 SDK 应用层加密；敏感日志必须按宿主安全
  需求评估 Data Protection 是否足够。
- 当前 `NSPrivacyCollectedDataTypes=[]` 只是开发占位，不是“SDK 不收集数据”的
  结论。SDK 会传输并可能持久化调用方日志，发布前必须由产品/隐私/法务确认数据
  类型、linkage 与 purpose，并验证 archive privacy report。

## 当前证据边界（2026-08-28）

已验证：

- iOS 26.5 与 iOS 26.3.1 arm64 Simulator 全量：248 total，242 passed，
  0 failed，6 个 opt-in 用例按设计 skipped。
- 真实本地 HTTPS redirect 4/4；BOE AK/SK 200 与随机错误 SK 401/403 映射
  2/2。BOE 证据早于最终 auth-retain 补丁；补丁不影响该 non-persistent wire
  路径，但最终源码精确复跑仍需凭证使用授权，不能把默认 skip 计作通过。
- ASan 与 TSan 全量均为 242 passed / 0 failed / 6 skipped。
- SwiftPM 严格 Swift 6、iOS 13 deployment 产品目标：arm64/x86_64 ×
  Debug/Release 全部 build；
  x86_64 在 Apple Silicon 上只验证 build/link，不声称 runtime。
- 外部 SwiftPM public lifecycle/resource/symbol gate；CocoaPods 完整 lint、两种
  `:path` consumer、Privacy resource 与最终 Mach-O symbol gate。
- 100 轮历史进程强杀恢复（50 buffered + 50 sync）全绿；最终 Release 通用
  Harness 又完成 3 + 3 轮，共 60/60 recovered、0 失败。
- persistent 503 首轮 3 次耗尽后同一 live Producer 自动恢复、只产生一个
  success；故障期间 local close 有界且下一次 open 能从 WAL 恢复，定向 2/2。
- 正式 2h Simulator soak v11 已通过：6908 accepted / observed / success、0
  failure、单 PID；RSS 覆盖率 96.81%、最大间隔 2 秒、首尾 5 分钟中位数下降
  2528 KiB、完整窗口斜率 -552.40 KiB/h。v6/v7/v8/v9 的产品缺陷与 v10 的合同
  变更中止均保留为历史证据，不冒充通过。

仍为 BLOCKED / 未验证：

- Xcode 14.3.1 / Swift 5.8 legacy runner 与 iOS 13 真机。
- STS 临时凭证；当前 BOE 材料只覆盖 AK/SK。
- 真机 Data Protection/background/Instruments；App Store archive privacy report。
- 隐私数据分类；远端 `0.0.2` tag 与发布动作。
测试通过不等于可发布。仓库内冻结合同与门禁状态见
[DECISIONS.md](DECISIONS.md) 和 [CORE_VERSION](CORE_VERSION)；完整执行证据保存在
workspace 的 `docs/research/tls-ios-producer-sdk-remediation-acceptance-2026-08-28.md`。

## 已知限制

- 无自动 STS Provider、ObjC public facade、contextFlow、XCFramework、SDK
  signature、rich metrics 或远端终态 flush。
- at-least-once 允许请求重放和重复日志；不承诺 exactly-once，也不承诺 App 被
  强杀后继续实时上传。持久化恢复的前提与排除项见“持久化模式”。
- 调用方必须强持有 `Producer` 直到 `close` 完成；未 close 就释放只保证
  best-effort 异步 destroy/不阻塞 deallocation，不保证剩余终态 callback。
- projectID 为未来 project 域名路由保留；当前只做 non-empty、NUL、CR/LF 的最小
  安全校验，不猜测长度/字符集。v0.3.1 destination update wire API 没有
  projectID 参数，单独修改 projectID 不会改变 sender target。
- Core 基线是 upstream v0.3.1，但当前 vendored 源码包含 iOS 集成补丁：custom
  transport retryability、内部符号可见性/LZ4 隐藏；不能描述为未修改上游包。
- bridge-level `flock` 只能约束遵守该 Bridge 协议的 SDK 实例，不能约束绕过
  Bridge 直接使用同一目录的其他 Core 实现。
- `requestID` 是服务端控制的可观测字段。Transport 将其截断为 256 个字符，并把
  非 `[A-Za-z0-9._:-]` 字符替换为下划线后再交给公开结果/错误；SDK 自有日志只
  记录稳定 FNV-1a 指纹。受限文本仍由服务端选择，因此 endpoint 必须属于可信
  服务边界，不能把源码审查表述为对任意恶意响应的绝对“零凭证反射”。
- `CoreAdapter` 为 internal test seam，不属于消费者 API。
- 每个请求当前都会通过 `NSLog` 输出脱敏诊断字段，没有 public 日志级别/关闭
  开关；高频 Release 场景应在 Beta 前完成默认关闭或可注入 logger 设计。
- C Core 会 secure-free 自有 SK/token buffer，但 Swift/Foundation/URLSession
  可能产生系统管理副本；不承诺进程内所有凭证副本即时归零。

## 文档与示例

- 决策：[DECISIONS.md](DECISIONS.md)
- 变更：[CHANGELOG.md](CHANGELOG.md)
- Core 固定版本：[CORE_VERSION](CORE_VERSION)
- 示例：[Examples/SwiftExample](Examples/SwiftExample/README.md)
- 第三方声明：[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)

许可证：Apache License 2.0，见仓库根 [LICENSE](../LICENSE)。
