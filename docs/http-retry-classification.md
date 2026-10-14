# HTTP retry classification

本文档描述 Producer v2 的公开 HTTP 重试合同，当前随 iOS delivery policy
alignment 一起维护，尚不代表已发布版本。

## 分类合同

Producer 只使用 HTTP 状态码和服务端返回的精确结构化 `ErrorCode`。不从
`ErrorMessage` 或响应正文做字符串匹配。

| 收到的结果 | `retryTransientHTTPResponses=true` | `false` 时 | 说明 |
|---|---|---|---|
| HTTP 408 | 有界重试，受 `maxAttempts` 和 `totalTimeout` 限制 | 不加入该扩展集合 | 这是客户端确实收到 408 的情况；无响应应按 transport 结果处理 |
| HTTP 499 | 有界重试，受 `maxAttempts` 和 `totalTimeout` 限制 | 不加入该扩展集合 | 499 常表示服务端记录到客户端已关闭请求，不等于客户端收到 499 |
| HTTP 400 + `ClientCanceled`、`Timeout`、`RequestTimeout` 或 `ConnectionClosed` | 有界重试 | 终止 | 必须是精确的结构化 `ErrorCode`；SDK 已知的本地显式取消优先终止 |
| HTTP 400 + 其他 `ErrorCode` 或缺失/未知 code | 终止 | 终止 | 参数、解析、鉴权语义和未知 400 不作 transient 推断 |
| HTTP 429/500/502/503/504 | 仍由 Core 的原有 HTTP 集合处理 | 有界重试 | `false` 用于保留旧 Core 合同 |

`maxAttempts=0` 只表示不限制尝试次数；`totalTimeout=90` 仍限制一个 retry
cycle。尝试次数包含第一次请求。`requestTimeout=90` 继续作为单次 attempt 的
整体 deadline，并且会被 retry cycle 的剩余预算进一步缩短；
`requestIdleTimeout=50` 是 URLSession idle timeout。`connectTimeout=10` 只是兼容
提示，不承诺独立 TCP timer，也不能覆盖 idle timeout。所有这些时间值都是秒。

408/499 的“收到”是客户端网络栈拿到 HTTP response 的意思。服务端 access log
中的 499 只能说明服务端观察到请求连接已关闭；客户端可能根本没有拿到响应，或在
响应写回前已经超时。此时不能把 access 499 直接当作客户端收到的 499。重发可能造成
至少一次重复投递，业务应携带稳定的 event ID 并在服务端或查询侧核对去重。

网络恢复通知仍然只是 hint：`notifyNetworkRecovered` 可以推进保留的 transient
任务，但不能恢复已经丢弃的内存批次，也不能把后台执行变成送达保证。

## 诊断记录

`onDiagnostic` 是可选、串行、异步回调。Swift 的
`ProducerDiagnostic` 和 Objective-C 的 `TLSProducerDiagnostic` 提供相同的安全
字段：`kind`、`reason`、`startID`、`endID`、`attemptCount`、`cycleAttemptCount`、
`elapsed`、`retryDelay`、`logCount`、`rawBytes`、`compressedBytes`、`httpCode`、
`transportCode`、`retryable`、`requestID` 和 `errorCode`。`httpCode=0` 表示没有可用的
HTTP response；不要附加日志正文、URL、服务端错误原文或凭据。

Swift 记录代码：

```swift
let configuration = try ProducerConfiguration(
    onDiagnostic: { event in
        print("kind=\(event.kind.rawValue) reason=\(event.reason.rawValue) " +
              "attempts=\(event.attemptCount)/\(event.cycleAttemptCount) " +
              "http=\(event.httpCode) transport=\(event.transportCode) " +
              "retryable=\(event.retryable) " +
              "errorCode=\(event.errorCode ?? "-") " +
              "requestID=\(event.requestID ?? "-")")
    }
)
```

Objective-C 记录代码：

```objc
TLSProducerConfiguration *configuration = [[TLSProducerConfiguration alloc] init];
configuration.onDiagnostic = ^(TLSProducerDiagnostic *event) {
    NSLog(@"kind=%ld reason=%ld attempts=%ld/%ld http=%ld transport=%ld "
          @"retryable=%d errorCode=%@ requestID=%@",
          (long)event.kind, (long)event.reason,
          (long)event.attemptCount, (long)event.cycleAttemptCount,
          (long)event.httpCode, (long)event.transportCode, event.retryable,
          event.errorCode ?: @"-", event.requestID ?: @"-");
};
```

初始化参数校验失败同样只使用稳定的 `errorCode`；诊断事件可报告
`openFailed`（`ProducerDiagnostic.Kind.openFailed.rawValue == 7`），不应把
configuration 错误描述或凭据写入日志。`opened`（5）、`admissionRejected`（4）、
`closed`（6）和 `openFailed`（7）是生命周期/准入事件，不是额外的 terminal
send-result 回调。Objective-C 入口的网络恢复方法名为
`notifyNetworkRecoveredWithError:`；Swift 导入为 `notifyNetworkRecovered(error:)`。

## 迁移边界

`retryTransientHTTPResponses` 默认是 `true`。需要保持旧 Core HTTP 集合时显式设为
`false`；Objective-C 对应字段为同名的
`retryTransientHTTPResponses`。Objective-C 的其余 retry 字段是 Swift
`RetryConfiguration` 的扁平映射：
`retryMaxAttempts`、`retryTotalTimeout`、`retryInitialInterval` 和
`retryMaxInterval`，单位仍是秒。

持久化模式继续通过 WAL 保留可重试任务；`.buffered` 不强制每次 admission 做 fsync，
`.sync` 才等待 WAL sync。内存模式只有在 `memoryRetryRetention > 0` 时才跨 cycle
保留，建议值为 `86400` 秒；它使用同一有限 buffer，进程退出后无法恢复。持久化与
memory-retained tasks 使用同一 HTTP 分类合同。

服务端版本边界必须保留：部署镜像标识为
`tls.epic_v6.6.2.f1c078a.2026_09_11_10_50`，但本地 `log-service` 无法解析
`f1c078a`；当前可核对的 fallback 是
`origin/epic_v6.6.2`，完整 SHA
`456ce7b505b08f87175f16dc33a890ddc02a6f9a`。SLS iOS 4.3.4 对真实 HTTP 400/408/499
的旧分类是 ordinary discard，首次 discard 最多额外重试一次，并非无限重试；无响应
则进入 transport/network 分类。不要把该旧行为当作 TLS 服务端 access-log 499 的响应
证据。
