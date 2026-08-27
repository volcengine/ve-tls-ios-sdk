# VolcengineTLSProducer

火山引擎日志服务（TLS）iOS Producer SDK——Swift-first 的日志采集与批量发送库。

> **⚠️ Development Preview — 不是 Beta 发布。**
>
> - C Core 发布门禁未满足，`RealCoreAdapter` **blocked**；当前 `Producer.open`
>   接入的是 PROVISIONAL 内存实现 `BundledCoreAdapter`（无网络、无持久化、
>   无压缩、无签名、无重试）。
> - 开发机无 macOS/Xcode 工具链，**编译与测试证据 pending**。
> - 不承诺 persistent/retry/ACK/真实发送；不得用于生产关键路径。
> - 状态依据：`Producer/DECISIONS.md`、`Producer/CORE_VERSION`、
>   `docs/research/tls-ios-producer-sdk-implementation-decision-ledger.md`。

## 需求

- iOS 13.0+
- Xcode 14.3.1 / Swift 5.8（Swift 语言模式 5.0 兼容）

## 安装

### Swift Package Manager

**Xcode 集成**：File → Add Package Dependencies… → 输入仓库 URL，
规则选择 *Branch: `producer`*：

```
https://github.com/volcengine/ve-tls-ios-sdk
```

将 `VolcengineTLSProducer` 产品加入你的 App target。

**Package.swift 依赖**（消费方为 SwiftPM 包时）：

```swift
.package(url: "https://github.com/volcengine/ve-tls-ios-sdk.git",
         branch: "producer")
```

### CocoaPods

```ruby
platform :ios, '13.0'
use_frameworks!

target 'YourApp' do
  pod 'VolcengineTLSProducer',
      :git => 'https://github.com/volcengine/ve-tls-ios-sdk.git',
      :branch => 'producer'
end
```

SwiftPM 与 CocoaPods 编译**同一份** `Producer/Sources/` 源码，不维护两套实现。

## Quick start

与 `Producer/Tests/ConsumerIntegrationTests/ConsumerIntegrationTests.swift`
的 `testConsumerSmoke` 相同的生命周期模式（示例额外加入了真实使用必需的
`updateDestination`——冻结的 P0 `open` 不接收 destination 参数）：

```swift
import VolcengineTLSProducer

let configuration = try ProducerConfiguration()
let credentials = Credentials(
    accessKeyID: "YOUR_AK",
    accessKeySecret: "YOUR_SK")

let producer = try await Producer.open(
    configuration: configuration,
    credentials: credentials
) { result in
    // 在 SDK 回调队列（非主线程）上投递；每个封批恰好一个终态 SendResult。
    print("send result: \(result.status), raw=\(result.rawBytes)")
}

// Destination 在 open 之后整组设置（current-target 语义：
// 此前已接收的日志后续改投新目标）。
try producer.updateDestination(Destination(
    endpoint: "https://tls-cn-beijing.volces.com",
    region: "cn-beijing",
    projectID: "YOUR_PROJECT_ID",
    topicID: "YOUR_TOPIC_ID"))

let event = LogEvent(contents: [
    "level": .string("info"),
    "message": .string("hello tls"),
])

// .normal 进入批量窗口（默认 1024 条 / 1 MiB / 3s linger 封批）。
try producer.add(event, mode: .normal)

// .immediate 立即封批并唤醒 sender；仍是异步操作，不等待网络/ACK。
try producer.add(event, mode: .immediate)

// close = 本地 worker/session 安全停止 + 本地持久化完成；
// 不表示所有日志已远端送达。
try await producer.close(timeout: 5)
```

## API 概览

P0 公共 API 已冻结（ledger §2），仅 5 个方法：

| 方法 | 语义 |
|---|---|
| `Producer.open(configuration:credentials:onSendResult:) async throws -> Producer` | 打开 producer；`onSendResult` 在 `configuration.callbackQueue` 上投递，每个封批恰好一个终态 `SendResult` |
| `add(_:mode:) throws` | 同步、非网络阻塞地接收一条日志；成功只表示达到当前 durability 的本地 admission 边界 |
| `updateCredentials(_:) throws` | 整组原子替换凭证（静态 AK/SK/STS） |
| `updateDestination(_:) throws` | 整组替换 endpoint/region/project/topic（current-target 语义） |
| `close(timeout:) async throws` | 本地安全停止；幂等；**不**表示远端全部送达 |

`AddMode`：`.normal`（默认，进入批量窗口）、`.immediate`（封批并唤醒 sender，
仍异步）。

关键类型：

| 类型 | 说明 |
|---|---|
| `ProducerConfiguration` | 构建期配置，open 时冻结。默认值对齐 SLS iOS wrapper：batch 1024/1MiB/3s、buffer 64MiB `.reject`、sendConcurrency 1、LZ4、connect 10s、request 15s、maxLogAge 7d、`.rewriteTimestamp`、`.retain`、source `"iOS"` |
| `Credentials` | AK/SK + 可选 STS token；`description`/`debugDescription` 永远脱敏 |
| `Destination` | endpoint（必须 HTTPS、无 userinfo/fragment）/region/projectID/topicID |
| `LogEvent` / `LogValue` | 值类型日志事件；`add` 按值快照。`LogValue` 支持 string/int/double/bool/null/array/dictionary/utf8Data；double 必须有限（NaN/Infinity 拒绝） |
| `SendResult` | 稳定最小字段：`status` / `rawBytes` / `compressedBytes` / `requestID?` / `error?` |
| `ProducerError` | 稳定错误合同（`errorCode` 字符串不变）：`configuration` / `invalidLog` / `invalidState` / `queueFull` / `bufferFull` / `singleLogTooLarge` / `persistence` / `transport` / `service` / `auth` / `quota` / `timeout` / `cancelled` / `closed` / `internal` |
| `ProducerMetadata` | log-group 级 source/fileName/tags |

> `CoreAdapter` 是 `public` 但 **PROVISIONAL** 的内部 seam（仅供测试 target
> 链接），不是公共 API 合同，Wave 3 可能重塑。消费者不应直接使用。

## 安全

- **HTTPS-only**：`Destination.validate()` 拒绝非 HTTPS endpoint、拒绝
  userinfo 与 fragment；SDK 没有也不会提供 trust-all 开关。
- **系统信任**：传输层使用 `URLSession` 默认 TLS 证书校验，不内置任何
  自定义 anchor/绕过逻辑。
- **凭证脱敏**：`Credentials` 的 `description`/`debugDescription` 永远输出
  `Credentials(<redacted>)`；凭证不写入日志、WAL、文件名、metrics 或错误描述；
  redacting logger 仅记录 method/脱敏 URL/status/duration/requestID/字节数，
  并 mask `Authorization` 与 `x-tls-*`。
- **无磁盘缓存**：`ProducerConfiguration` 对 `urlSessionConfiguration` 做防御性
  清洗——清空 `urlCache`/`httpCookieStorage`/`urlCredentialStorage`，禁用自动
  cookies（默认即 `.ephemeral`）。
- **redirect 约束**：仅允许同 scheme+host 的重定向（设计合同）。

## 证据边界

**代码存在 ≠ 编译通过 ≠ 真机通过 ≠ Real Core 集成 ≠ Beta。**

- 本仓库的 Producer 代码已编写并经过静态审查；开发机（Linux）无
  xcodebuild/swift/pod，**未编译、未运行任何测试**。
- 所有测试（Contract/Bridge/Transport/Persistence/ConsumerIntegration）
  当前状态是"已编写，执行待 macOS + Xcode"。
- `Producer.open` 行为由 `BundledCoreAdapter`（PROVISIONAL 内存实现）提供；
  其行为（封批即成功、`compressedBytes == rawBytes` 等）**不是**发布行为承诺。
- Real Core 集成被 C Core 发布门禁阻塞（见 `Producer/CORE_VERSION`）。
- 任何 BOE/真机/soak/性能证据当前均不存在。

## 已知限制

- **无自动 STS Provider**（P1）：仅支持静态 AK/SK/STS 初始化与整组原子更新；
  凭证轮换需调用方自行调度 `updateCredentials`。
- **无 Objective-C facade**（P1）：纯 Swift API。
- **无 contextFlow**（P1）。
- **无 XCFramework / binary SwiftPM / SDK 签名**（P1）：仅源码分发。
- **`close` 语义**：成功 = 本地 worker/session 安全停止 + 本地持久化完成，
  **不**表示远端全部送达；无 `CloseReport`、无远端终态 `flush`。
- **`.immediate` 仍异步**：封批并唤醒 sender，但 `add` 不等待网络/ACK/服务端接收。
- **无 exactly-once 承诺**；App 被强杀后不承诺继续实时上传。
- **`BufferFullPolicy.block`** 在 `BundledCoreAdapter` 下降级为 `.reject`，
  由 RealCoreAdapter 实现。
- **无** `resumeDelivery` / `deliverySuspended-auth` / `retryDelayed` 公共状态机、
  无 rich metrics（均为 P0 之外）。
- `Producer`/`ProducerConfiguration` 未标注 `Sendable`（Swift 6 模式前需评估，
  见 `DECISIONS.md` Wave 3 跟进项）。

## 示例

最小 iOS App 示例见 [`Examples/SwiftExample`](Examples/SwiftExample/README.md)。

## 目录

```
Producer/
├── DECISIONS.md            # 实施决策索引（仓库内权威）
├── CORE_VERSION            # C Core 版本与门禁状态（BLOCKED）
├── Sources/
│   ├── VolcengineTLSProducer/  # Swift 公共 API（唯一公共产品）
│   ├── TLSProducerBridge/      # ObjC 内部桥（非公共产品）
│   └── CTLSProducerCore/       # C Core 占位 target
├── Tests/                  # Contract/Bridge/Transport/Persistence/ConsumerIntegration
└── Examples/SwiftExample/  # 最小 iOS App 示例
```

## 许可证

Apache License 2.0，见仓库根 [LICENSE](../LICENSE)。第三方声明见
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)。
