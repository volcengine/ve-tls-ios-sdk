# 配置参数

`ProducerConfiguration` 是可变值类型。初始化时会校验参数，`Producer.open` 还会重新校验并
保存当时的配置。打开成功后，修改原配置不会影响正在运行的 Producer。

## BatchConfiguration

| 参数 | 类型 | 默认值 | 有效范围 | 说明 |
|---|---|---:|---|---|
| `maxLogCount` | `Int` | 1024 | 1...10000 | 一个批次的最大日志数 |
| `maxRawBytes` | `Int` | 1 MiB | 1...9,961,472 字节 | 一个批次的未压缩内容上限；9.5 MiB 为 10 MB 服务限制预留空间 |
| `linger` | `TimeInterval` | 3 秒 | 0...`Int32.max` 毫秒 | 非空批次最长等待时间；精度为整毫秒 |

日志数、原始字节数或等待时间任一达到阈值时都会封批。

## BufferConfiguration

| 参数 | 类型 | 默认值 | 有效范围 | 说明 |
|---|---|---:|---|---|
| `maxBytes` | `Int` | 64 MiB | 1 字节...256 MiB | 单个 Producer 的待处理内存字节预算 |
| `fullPolicy` | `BufferFullPolicy` | `.reject` | `.reject` / `.block` | 满时立即拒绝或有界等待 |
| `blockTimeout` | `TimeInterval` | 1 秒 | `.block` 时至少 1 毫秒 | 有限值，精度为整毫秒，上限为 `Int32.max` 毫秒 |

`.block` 会阻塞调用线程，适合在后台线程使用，避免影响 UI 响应。`.reject` 不使用
`blockTimeout`，其配置校验仍只接受有限值。持久化模式即使使用 `.reject` 也可能先执行 WAL I/O；它不保证磁盘操作不阻塞，
也不保证 `bufferFull` 发生前未保存日志。参见[持久化与恢复](../guides/persistence-and-recovery.md#add-抛错后是否还会发送)。

## ProducerConfiguration

| 参数 | 类型 | 默认值 | 约束与语义 |
|---|---|---:|---|
| `batch` | `BatchConfiguration` | 见上表 | 打开时冻结 |
| `buffer` | `BufferConfiguration` | 见上表 | 打开时冻结 |
| `sendConcurrency` | `Int` | 1 | 1...8 个发送线程 |
| `compression` | `Compression` | `.lz4` | `.lz4` 或 `.disabled` |
| `persistence` | `Persistence` | `.disabled` | `.disabled`、`.memory`、`.buffered`、`.sync` |
| `connectTimeout` | `TimeInterval` | 10 秒 | 大于 0、至少 1 毫秒、整毫秒、有限且不超过 `Int32.max` 毫秒；URLSession 兼容提示，不保证独立 TCP 连接计时器，也不会覆盖 `requestIdleTimeout` |
| `requestTimeout` | `TimeInterval` | 90 秒 | 同上；单次 attempt 的整体安全截止时间，并会被 `retry.totalTimeout` 的剩余预算进一步裁剪 |
| `requestIdleTimeout` | `TimeInterval` | 50 秒 | 同上；URLSession 空闲超时，网络加载活动会重置计时 |
| `retry` | `RetryConfiguration` | `RetryConfiguration()` | `maxAttempts=0`、`totalTimeout=90` 秒、`initialInterval=0.5` 秒、`maxInterval=10` 秒、`retryTransientHTTPResponses=true` |
| `memoryRetryRetention` | `TimeInterval` | 0 秒 | 仅内存模式的跨 retry cycle 保留窗口；0 关闭；仍受同一有限 buffer 约束，进程退出后不能恢复 |
| `onDiagnostic` | `(@Sendable (ProducerDiagnostic) -> Void)?` | `nil` | 在 SDK 独立的串行诊断队列异步投递；只应记录公开的数值、状态、HTTP/transport code、`requestID` 和 `errorCode` |
| `diagnosticLogLevel` | `ProducerDiagnosticLogLevel` | `.info` | 只过滤文本 `diagnosticHandler`；`.off` 不关闭结构化 `onDiagnostic` |
| `diagnosticHandler` | `(@Sendable (ProducerDiagnosticLogLevel, String) -> Void)?` | `nil` | 可选的安全 JSON 文本回调；由 SDK 独立的串行诊断队列投递 |
| `metadata` | `ProducerMetadata` | 平台默认 | 可使用空字符串或空 tags；字符串不支持 NUL |
| `maxLogAge` | `TimeInterval` | 7 天 | 大于 0、有限、整秒且不溢出 64 位毫秒 |
| `expiredLogPolicy` | `ExpiredLogPolicy` | `.rewriteTimestamp` | 过期日志改写当前时间或丢弃 |
| `unauthorizedPolicy` | `UnauthorizedPolicy` | `.retain` | 401/403 后保留或丢弃 |
| `callbackQueue` | `DispatchQueue` | SDK 串行 utility 队列 | 指定回调执行环境；SDK 使用私有串行投递队列保证结果串行 |
| `urlSessionConfiguration` | `URLSessionConfiguration` | `.ephemeral` | 打开时复制并清除 cache、Cookie 和 credential storage |
| `automaticLifecycleHandling` | `Bool` | iOS App 为 `true`；Extension/macOS 为 `false` | macOS 上无效果 |
| `producerID` | `String?` | `nil` | `.buffered` / `.sync` 必填；字符集 `[A-Za-z0-9._-]`；最多 64 字节；不能为 `.` / `..` |
| `destination` | `Destination?` | `nil` | 公共 `Producer.open` 必填 |

所有公开字段在 `open` 后都被冻结。运行期间只支持通过 `updateCredentials` 和
`updateDestination` 原子更新对应整组值。

### RetryConfiguration

`maxAttempts` 包含首次请求；为 0 表示不限制尝试次数，但 `totalTimeout` 仍然生效。
`maxInterval` 是 Core 加 20% 抖动前的退避上限。`retryTransientHTTPResponses` 默认开启时，
会在有界预算内重试收到的 408/499，以及 400 中结构化标记为 transient 的上传错误；参数错误和
未知 400 仍终止。关闭该开关时，HTTP 重试集合回退为 Core 的 429/500/502/503/504。

`onDiagnostic` 和 `diagnosticHandler` 使用每个 Producer 独立的串行诊断队列，与
`onSendResult` 的 `callbackQueue` 隔离。同一事件先投递结构化回调，再投递文本回调；业务结果
回调仍按 `callbackQueue` 执行。结构化事件字段只包含安全的计数、状态、HTTP/transport code、
`retryable`、`requestID` 和 `errorCode`，回调不会补回已经丢弃的批次。

### 文本诊断适配器（未发布）

`ProducerDiagnosticLogLevel` 的原始值固定为 `.debug = 0`、`.info = 1`、`.warning = 2`、
`.error = 3`、`.off = 4`，默认 `.info`；`diagnosticHandler` 默认 `nil`。等级是阈值，只影响
文本消息。每条文本消息是 SDK 生成的安全 JSON，最大 4 KiB UTF-8；诊断 FIFO 最大 1024 条，
满时 best effort 丢弃并在后续报告丢弃计数。SDK 每 60 秒发累计 summary，`close` 前再发一次。

```swift
var configuration = try ProducerConfiguration(diagnosticLogLevel: .info)
configuration.diagnosticHandler = { _, message in
    appFileLogger.append(message)
}
```

Objective-C 使用 `TLSProducerDiagnosticLogLevel` 和
`void (^)(NSInteger level, NSString *message)`：

```objc
configuration.diagnosticLogLevel = TLSProducerDiagnosticLogLevelInfo;
configuration.diagnosticHandler = ^(NSInteger level, NSString *message) {
    BXLogI(@"[VolcTLS-SDK][terminal] %@", message);
};
```

App 负责 logger 的文件路径、轮转、导出和 `fsync`；handler 直接交给文件 logger，不自行重组
SDK 内部数据。同一文件由两个 Producer 写入时，logger 必须并发安全。handler 不得重新进入同一
Producer，也不得同步等待自身文件回调。诊断仅观察，不改变上传、重试、超时或 WAL。`open` 会
冻结等级和 handler；本节新 API 属于待发布的 2.0.2，线上 2.0.1 不能直接配置。

## 枚举

### Compression

- `.lz4`：压缩批次，默认值；
- `.disabled`：不压缩。

### Persistence

- `.disabled`：仅内存；
- `.memory`：显式内存模式，与 `.disabled` 具有相同持久性语义；
- `.buffered`：缓冲 WAL；
- `.sync`：每次本地接收等待 WAL 同步。

### ExpiredLogPolicy

- `.rewriteTimestamp`：发送前将过期日志时间改为当前时间；
- `.drop`：丢弃过期日志。

### UnauthorizedPolicy

- `.retain`：保留数据，等待凭证更新；
- `.drop`：收到明确未授权响应后丢弃数据。

## ProducerMetadata

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `source` | `String` | iOS 为 `"iOS"`，macOS 为 `"macOS"` | 日志来源标记，可设为 `""` |
| `fileName` | `String?` | `nil` | 日志组文件名标记，可为 `nil` 或 `""` |
| `tags` | `[String: String]` | `[:]` | 每个日志组携带的静态 tags，可为空字典；key 和 value 可为空字符串 |

Metadata 对整个 Producer 生效，不由单条 `LogEvent` 覆盖。不需要来源或文件名标记时，可使用
`ProducerMetadata(source: "", fileName: nil, tags: [:])`。字符串字段不支持内嵌 NUL（`\0`），
以避免传入底层接口时被截断。

## Destination

| 参数 | 说明 |
|---|---|
| `endpoint` | 带 host 的 HTTPS origin；允许端口；不接受 path、query、userinfo 或 fragment |
| `region` | 非空；不能包含 NUL、换行或首尾空白 |
| `projectID` | 日志项目 ID；非空；不能包含 NUL、换行或首尾空白 |
| `topicID` | 非空；不能包含 NUL、换行或首尾空白 |

## close timeout

`close(timeout:)` 的 timeout 由每次调用传入，不属于打开时配置。有效范围为 0 到
`Int32.max` 毫秒，接受有限值，精度为整毫秒。0 表示不额外等待，但仍可能立即完成已经满足的本地关闭。

## 配置示例

```swift
let configuration = try ProducerConfiguration(
    batch: BatchConfiguration(
        maxLogCount: 1024,
        maxRawBytes: 1024 * 1024,
        linger: 3
    ),
    buffer: BufferConfiguration(
        maxBytes: 64 * 1024 * 1024,
        fullPolicy: .reject
    ),
    sendConcurrency: 2,
    compression: .lz4,
    persistence: .buffered,
    connectTimeout: 10,
    requestTimeout: 90,
    requestIdleTimeout: 50,
    retry: RetryConfiguration(
        maxAttempts: 0,
        totalTimeout: 90,
        initialInterval: 0.5,
        maxInterval: 10,
        retryTransientHTTPResponses: true
    ),
    memoryRetryRetention: 0,
    metadata: ProducerMetadata(
        source: "my-app",
        tags: ["environment": "production"]
    ),
    maxLogAge: 7 * 24 * 60 * 60,
    expiredLogPolicy: .rewriteTimestamp,
    unauthorizedPolicy: .retain,
    producerID: "main-app",
    destination: destination
)
```

参数越大不一定性能越好。先使用默认值，再按[性能测试](../operations/performance.md)的方法对
真实日志大小和网络条件进行测量。
