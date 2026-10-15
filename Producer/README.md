# VolcengineTLSProducer

`VolcengineTLSProducer` 是面向 iOS、iPadOS 和原生 macOS 的异步日志上传 SDK，提供 Swift 和
Objective-C 接口。

- [安装](../docs/getting-started/installation.md)
- [快速开始](../docs/getting-started/quick-start.md)
- [Objective-C 接入](../docs/getting-started/objective-c.md)
- [配置参数](../docs/reference/configuration.md)
- [日志模型](../docs/reference/log-model.md)
- [平台兼容性](../docs/reference/compatibility.md)
- [完整文档](../docs/README.md)

iOS 示例工程位于 [Examples/SwiftExample](Examples/SwiftExample/README.md)。

## 交付策略快速配置（未发布）

下面的配置使用公开 Producer v2 API。所有 `TimeInterval` 参数的单位都是秒，
不是毫秒；配置在 `open` 时复制并冻结。

Swift 示例（WAL 持久化）：

```swift
let configuration = try ProducerConfiguration(
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
    onDiagnostic: { event in
        print("producer diagnostic kind=\(event.kind.rawValue) " +
              "reason=\(event.reason.rawValue) attempts=\(event.attemptCount) " +
              "http=\(event.httpCode) retryable=\(event.retryable) " +
              "errorCode=\(event.errorCode ?? "-") " +
              "requestID=\(event.requestID ?? "-")")
    },
    producerID: "ios-producer",
    destination: Destination(
        endpoint: "https://tls-cn-beijing.volces.com",
        region: "cn-beijing",
        projectID: "YOUR_PROJECT_ID",
        topicID: "YOUR_TOPIC_ID"
    )
)
```

`persistence: .buffered` 已由 WAL 保留可重试失败；如果业务明确选择内存模式并希望
跨 retry cycle 保留，可改为 `persistence: .memory`、省略 `producerID`，并设置
`memoryRetryRetention: 86_400`。内存保留仍受同一有限 buffer 约束，进程退出后不能恢复。
已进入内存保留的批次会在 `close` 时以 closed 失败结束，不再获得最后一次发送机会；需要跨 close
恢复时应使用 WAL。详见[关闭与恢复边界](../docs/reference/api-and-errors.md#close)。

Objective-C 的字段是同一合同的扁平映射：

```objc
TLSProducerConfiguration *configuration = [[TLSProducerConfiguration alloc] init];
configuration.persistence = TLSPersistenceBuffered;
configuration.producerID = @"ios-producer";
configuration.connectTimeout = 10.0;
configuration.requestTimeout = 90.0;
configuration.requestIdleTimeout = 50.0;
configuration.retryMaxAttempts = 0;
configuration.retryTotalTimeout = 90.0;
configuration.retryInitialInterval = 0.5;
configuration.retryMaxInterval = 10.0;
configuration.retryTransientHTTPResponses = YES;
configuration.memoryRetryRetention = 0.0;
configuration.onDiagnostic = ^(TLSProducerDiagnostic *event) {
    NSLog(@"producer diagnostic kind=%ld reason=%ld attempts=%ld http=%ld "
          @"retryable=%d errorCode=%@ requestID=%@",
          (long)event.kind, (long)event.reason, (long)event.attemptCount,
          (long)event.httpCode, event.retryable,
          event.errorCode ?: @"-", event.requestID ?: @"-");
};
```

Objective-C 内存模式对应 `TLSPersistenceMemory` 和
`memoryRetryRetention = 86400.0`；持久化模式需要稳定的 `producerID`。Swift 和
Objective-C 的 `onDiagnostic` 都只应记录数值计数、稳定 kind/reason、HTTP/transport
code、`retryable`、`requestID` 和 `errorCode`，不要记录日志正文、URL、服务端原文或凭据。

### 文本诊断适配器（未发布）

文本诊断使用 `ProducerDiagnosticLogLevel`，原始值固定为 `debug = 0`、`info = 1`、
`warning = 2`、`error = 3`、`off = 4`。默认值是 `.info`，`diagnosticHandler` 默认为
`nil`。等级只过滤文本消息；即使设置为 `.off`，结构化 `onDiagnostic` 仍会收到事件。

Swift 的配置字段为：

```swift
var configuration = try ProducerConfiguration(
    diagnosticLogLevel: .info,
    diagnosticHandler: { _, message in
        appFileLogger.append(message)
    },
    destination: Destination(
        endpoint: "https://tls-cn-beijing.volces.com",
        region: "cn-beijing",
        projectID: "YOUR_PROJECT_ID",
        topicID: "YOUR_TOPIC_ID"
    )
)
```

Objective-C 映射为 `TLSProducerDiagnosticLogLevel` 和
`void (^)(NSInteger level, NSString *message)`：

```objc
configuration.diagnosticLogLevel = TLSProducerDiagnosticLogLevelInfo;
configuration.diagnosticHandler = ^(NSInteger level, NSString *message) {
    BXLogI(@"[VolcTLS-SDK][terminal] %@", message);
};
```

SDK 为每个 Producer 建立独立的串行诊断队列，与 `onSendResult` 使用的
`callbackQueue` 隔离。同一事件先投递结构化 `onDiagnostic`，再按等级和限频规则决定是否投递文本
`diagnosticHandler`；业务结果回调仍遵循 `callbackQueue` 合同。文本消息是 SDK 生成的安全
JSON，每条最多 4 KiB UTF-8。诊断 FIFO 最多保留 1024 条；满队列时 best effort 丢弃，并在
后续可投递时报告丢弃计数。SDK 每 60 秒给出累计 summary，并在 `close` 前再给出一次 summary。

文本输出按每个 Producer 的单调时钟滚动 60 秒限额：Debug/Info 共 30 条、32 KiB，
Warning/Error 另有 30 条、32 KiB，字节预算包含一字节换行，不含 App logger 自行增加的前缀等开销。相同事件种类、原因、错误码与处置的
Warning/Error 在 60 秒内最多输出一条，不以不断变化的 RequestID 或批次 ID 区分重复故障。
被抑制的数量在下一条可输出消息中通过 `text_suppressed_total` 和
`text_suppressed_since_last_report` 汇总；与诊断队列溢出的 `diagnostic_dropped_*` 分开。
限频不减少结构化 `onDiagnostic` 的事件；Debug 文本同样受上限约束，不能用文本条数推算请求数。
限额按实例计算，多个 Producer 的输出量需要相加，反复重建实例会重新开始计额。

App 负责文件 logger、路径、轮转、导出和 `fsync`。建议设置单文件 2 MiB、最多 3 个文件，
写入前轮转并覆盖最旧文件，合计最多约 6 MiB；磁盘写入失败应停止文件写入，避免递归记录错误。
限频只能降低增长速度，不能替代文件容量上限。App 如果也将 `onDiagnostic` 写入文件，需要自行
给该通道限频。handler 应直接把 SDK 消息交给 logger，
不要从 SDK 内部字段自行重组消息；两个 Producer 写同一个文件时，logger 必须支持并发调用。
handler 不得重新进入同一个 Producer，也不得同步等待自己的文件回调。诊断只用于观察，不改变
上传、重试、超时或 WAL 行为。

`open` 会冻结诊断等级和 handler；之后修改原配置不会影响已打开的 Producer。本节 API 属于
待发布的 2.0.2；线上 2.0.1 不能直接配置这些字段。

`automaticLifecycleHandling` 在 iOS App 进程默认开启，在 App Extension 和 macOS 默认关闭；
它只负责接入系统生命周期通知、触发后台 flush 和回到前台后的 retry，不保证系统挂起期间送达。

HTTP 策略、SLS 迁移边界和 access-log 499 的处理见
[HTTP retry classification](../docs/http-retry-classification.md) 与
[iOS delivery policy contract](../docs/ios-delivery-policy-contract.md)。

网络恢复通知只是 hint：Swift 使用 `try producer.notifyNetworkRecovered()`；
Objective-C 使用 `notifyNetworkRecoveredWithError:`。它不会恢复已经丢弃的批次，也不构成后台送达保证。
