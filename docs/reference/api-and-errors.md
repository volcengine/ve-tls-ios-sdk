# API 与错误码

本页介绍 Producer v2 的 Swift 接口。Objective-C 对应接口见 [Objective-C 接入](../getting-started/objective-c.md)。以下签名省略了默认参数的完整类型限定。

## Credentials

```swift
public init(
    accessKeyID: String,
    accessKeySecret: String,
    securityToken: String? = nil
)
```

AK、SK 和可选 STS token 始终作为整组传入。`description` 与 `debugDescription` 固定返回脱敏
文本。空字段、换行和 NUL 会在 `open` 或更新边界被拒绝。

## Destination

```swift
public init(
    endpoint: String,
    region: String,
    projectID: String,
    topicID: String
)

public func validate() throws
```

`validate()` 可用于业务配置预检；`open` 和 `updateDestination` 仍会重新校验。`region`、
`projectID` 或 `topicID` 含有首尾空白时，校验会失败。

## 网络、重试与诊断配置

`ProducerConfiguration` 的网络相关默认值如下：

| 字段 | 默认值 | 语义 |
|---|---:|---|
| `connectTimeout` | 10 秒 | URLSession 兼容提示，不保证独立 TCP 连接截止时间 |
| `requestTimeout` | 90 秒 | 单次 attempt 的整体安全截止，会被 retry 剩余预算裁剪 |
| `requestIdleTimeout` | 50 秒 | URLSession 空闲超时，网络加载活动会重置 |
| `retry` | `RetryConfiguration()` | `maxAttempts=0`、`totalTimeout=90` 秒、`initialInterval=0.5` 秒、`maxInterval=10` 秒、`retryTransientHTTPResponses=true` |
| `memoryRetryRetention` | 0 秒 | 内存模式跨 retry cycle 保留窗口；0 关闭，进程退出后不能恢复 |
| `onDiagnostic` | `nil` | 在 SDK 独立的串行诊断队列异步投递的结构化回调 |
| `diagnosticLogLevel` | `.info` | 文本诊断等级；`.off` 只关闭文本回调 |
| `diagnosticHandler` | `nil` | 可选的安全 JSON 文本回调 |

`RetryConfiguration.maxAttempts` 包含首次请求；0 取消尝试次数上限，但不取消
`totalTimeout`。`retryTransientHTTPResponses` 开启时，在预算内重试收到的 408/499 和 400 中
结构化标记为 transient 的上传错误；参数错误和未知 400 终止。关闭后回退到 429/500/502/503/504。
`TimeInterval` 配置统一使用秒。Objective-C 使用同名扁平字段
`retryMaxAttempts`、`retryTotalTimeout`、`retryInitialInterval`、`retryMaxInterval`、
`retryTransientHTTPResponses`、`memoryRetryRetention`、`onDiagnostic`、
`diagnosticLogLevel` 和 `diagnosticHandler`。

`onDiagnostic` 只应记录事件的数值计数、稳定 kind/reason、HTTP/transport code、`retryable`、
`requestID` 和 `errorCode`，不要记录日志正文、URL 或凭据。它和文本
`diagnosticHandler` 在每个 Producer 独立的串行诊断队列中投递，与 `onSendResult` 的
`callbackQueue` 隔离；同一事件先投递结构化回调，再投递文本回调，业务结果回调合同不变。

### 文本诊断适配器（未发布）

Swift API 为：

```swift
public enum ProducerDiagnosticLogLevel: Int {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case off = 4
}

public var diagnosticLogLevel: ProducerDiagnosticLogLevel = .info
public var diagnosticHandler:
    (@Sendable (ProducerDiagnosticLogLevel, String) -> Void)? = nil
```

Objective-C 映射为以下公开 enum 和 `ProducerConfiguration` 属性：

```objc
typedef NS_ENUM(NSInteger, TLSProducerDiagnosticLogLevel) {
    TLSProducerDiagnosticLogLevelDebug = 0,
    TLSProducerDiagnosticLogLevelInfo = 1,
    TLSProducerDiagnosticLogLevelWarning = 2,
    TLSProducerDiagnosticLogLevelError = 3,
    TLSProducerDiagnosticLogLevelOff = 4,
};

@property(nonatomic) TLSProducerDiagnosticLogLevel diagnosticLogLevel;
@property(nonatomic, copy, nullable) void (^diagnosticHandler)(NSInteger level,
                                                                 NSString *message);
```

配置示例：

```objc
configuration.diagnosticLogLevel = TLSProducerDiagnosticLogLevelInfo;
configuration.diagnosticHandler = ^(NSInteger level, NSString *message) {
    BXLogI(@"[VolcTLS-SDK][terminal] %@", message);
};
```

等级只过滤文本，`.off` 不影响结构化 `onDiagnostic`。每条文本消息是 SDK 生成的安全 JSON，
最大 4 KiB UTF-8；每个 Producer 的诊断 FIFO 最大 1024 条，满时 best effort 丢弃并在后续
报告丢弃计数。SDK 每 60 秒发送累计 summary，并在 `close` 前发送一次 summary。App 负责
文件 logger、路径、轮转、导出和 `fsync`，handler 应直接交给 logger，不自行拼接 SDK 内部数据；
两个 Producer 共用文件时 logger 必须并发安全。handler 不得重新进入同一 Producer，也不得
同步等待自己的文件回调。诊断只观察，不改变上传、重试、超时或 WAL。

`open` 会冻结等级和 handler；这些新增 API 属于待发布的 2.0.2，线上 2.0.1 不能直接配置。

## Producer.open

```swift
public static func open(
    configuration: ProducerConfiguration,
    credentials: Credentials,
    onSendResult: (@Sendable (SendResult) -> Void)? = nil
) async throws -> Producer
```

打开时重新校验配置、凭证和目标，创建本地引擎，并在持久化模式下检查和恢复 WAL。失败时不会
返回半打开的 Producer。

## add

```swift
public func add(_ log: LogEvent, mode: AddMode = .normal) throws
```

- `.normal`：进入普通批处理窗口；
- `.immediate`：接收后立即封批并唤醒发送线程。

两种模式都不等待网络或服务端确认。成功只表示达到所选本地接收边界。

## updateCredentials

```swift
public func updateCredentials(_ credentials: Credentials) throws
```

原子替换 AK、SK 和可选 STS token 整组值。更新失败时保留旧组。

## updateDestination

```swift
public func updateDestination(_ destination: Destination) throws
```

原子替换 endpoint、region、project 和 topic。此前已接收但尚未发送的日志会使用新目标，属于
current-target 语义。

## notifyNetworkRecovered

```swift
public func notifyNetworkRecovered() throws
```

这是网络恢复提示：它推进仍保留的 transient 失败，不取消进行中的请求，也不恢复已经丢弃的批次。
Objective-C 入口为 `notifyNetworkRecoveredWithError:`；该提示不保证后台期间送达。

## close

```swift
public func close(timeout: TimeInterval) async throws
```

封闭新写入，停止 worker，并在 timeout 内完成本地封批和持久化工作。成功不表示所有日志已
远端送达。并发等待同一次关闭的调用者收到相同结果；失败后可再次调用 `close` 重试本地关闭。

非持久化模式中，因暂态失败而进入 `memoryRetryRetention` 的已保留批次会在 close 时结束，
其发送结果为 `.failure` / `ProducerError.closed`。close 的 timeout 不会给这些批次追加最后一次
发送机会；重新打开内存实例也不会恢复它们。持久化模式中的延迟重试则保留未确认 WAL，
不人为合成同类终止回调，后续使用相同 `producerID` 打开时恢复。iOS 进入后台不等同于 close；
自动生命周期处理沿用后台封批和前台唤醒，不保证系统挂起期间送达。

## SendResult

每个由当前活跃 Producer 拥有的封闭批次最多回调一次终态结果：

| 字段 | 说明 |
|---|---|
| `status` | `.success` 或 `.failure` |
| `rawBytes` | Core 统计的未压缩批次字节数，包含日志编码和日志组元数据，不等同于业务 key/value 字节之和 |
| `compressedBytes` | 压缩后批次字节数 |
| `requestID` | 服务端 Request ID，可能为空 |
| `error` | 失败原因；成功时为空 |

回调在 `configuration.callbackQueue` 上串行交付。持久化批次可能在当前实例关闭后由下一实例
恢复，因此旧实例不保证为这类批次收到人为合成的失败回调。

## 稳定错误码

`ProducerError.errorCode` 是稳定的错误码字符串。

| errorCode | 含义 | 常见处理 |
|---|---|---|
| `configuration` | 配置、凭证或目标不合法 | 相同值重试仍会失败，先修正输入 |
| `invalidLog` | 一个或多个日志字段不合法 | 根据返回的字段路径修正整条日志 |
| `invalidState` | 当前生命周期状态不允许操作 | `open` 未完成时等待其完成，或重新创建实例 |
| `queueFull` | 本地接收队列已满 | 降采样、稍后写入或调整吞吐配置 |
| `bufferFull` | 内存缓冲预算已用尽 | 恢复网络/认证、降采样或调整缓冲区 |
| `singleLogTooLarge` | 单条日志超过批次字节上限 | 拆分或缩小字段 |
| `persistence` | WAL、目录或恢复失败 | 检查磁盘空间、目录所有权和 `producerID` |
| `transport` | DNS、TLS、连接或其他网络失败 | 检查网络和 endpoint；注意重试可能重复 |
| `service` | 服务端返回非成功状态 | 按 HTTP code、message 和 Request ID 排查 |
| `auth` | 认证或授权失败 | 刷新整组凭证并检查权限 |
| `quota` | 限流或配额拒绝 | 降低速率并检查服务配额 |
| `timeout` | 有界等待超过截止时间 | 检查网络或本地关闭；重复写入已接收事件会增加重复风险 |
| `cancelled` | 操作被取消 | 根据退出状态决定是否恢复 |
| `closed` | Producer 正在关闭或已经关闭 | 需要继续写入时创建新实例 |
| `internal` | SDK 内部不变量或引擎错误 | 保留安全诊断信息和版本，升级或提交问题 |

### ProducerError 关联值

- `configuration(String)`：脱敏原因；
- `invalidLog([String])`：违反规则的字段路径；
- `persistence(String)`、`transport(String)`、`internal(String)`：稳定、脱敏的错误摘要；
- `service(code:message:requestID:)`：HTTP 状态码、服务错误信息和可选 Request ID。

错误描述不会有意包含凭证、Authorization 或完整日志正文。调用方自定义网络层和日志系统仍需
遵守相同脱敏要求。

## 重试注意事项

Producer 内部已经处理批次级可重试错误。对一个已经 `add` 成功的事件，因为终态超时或 transport
失败而无条件再次调用 `add` 会放大重复，原请求可能已经到达服务端。

需要业务补偿时，建议使用稳定 `event_id`，并先查询或按业务幂等规则处理。

持久化模式下，`add` 抛错也可能留下记录：WAL 写入后再遇到内存背压、同步落盘失败或并发
关闭，下一次使用相同 `producerID` 打开时仍可能恢复发送。`bufferFull`、`timeout`、`persistence`
或写入途中的 `closed` 不等同于“未保存”；重试沿用同一个 `event_id` 可避免重复事件难以识别。
前置日志校验失败与调用已经关闭的实例不在此范围内。详见[持久化与恢复](../guides/persistence-and-recovery.md#add-抛错后是否还会发送)。
