# 网络、超时与重试

Producer 负责请求签名、压缩、发送和批次级重试。Producer 下方再增加透明 HTTP 重试会使一次
逻辑批次被重复发送更多次。

## Endpoint 规则

`Destination.endpoint` 仅接受 HTTPS origin，例如：

```text
https://tls-cn-beijing.volces.com
https://logs.example.com:8443
```

endpoint 需要包含 host，可以带合法端口；以下内容不在支持范围内：

- 路径、query 或 fragment；
- 用户名或密码；
- 空端口、换行或 NUL 字符。

## 超时

| 参数 | 默认值 | 含义 |
|---|---:|---|
| `connectTimeout` | 10 秒 | URLSession 兼容提示；不能保证独立 TCP 连接截止时间，也不会覆盖 `requestIdleTimeout` |
| `requestTimeout` | 90 秒 | 单次 attempt 的整体安全截止时间，并被 `retry.totalTimeout` 的剩余预算裁剪 |
| `requestIdleTimeout` | 50 秒 | URLSession 空闲超时；网络加载活动会重置计时 |
| `close(timeout:)` | 调用方指定 | 本地停止、封批和持久化工作的等待上限 |

这些值需要是有限的整毫秒，并落在 SDK 支持范围内。`close` 的超时与网络请求超时不是
同一个概念。

## 重试语义

SDK 对可重试的网络失败和服务错误执行有界退避重试。默认配置为
`RetryConfiguration(maxAttempts: 0, totalTimeout: 90, initialInterval: 0.5,
maxInterval: 10, retryTransientHTTPResponses: true)`；0 表示不限制尝试次数，
`totalTimeout` 仍限制一个 delivery cycle，`maxInterval` 是 Core 抖动前的标称上限。
`requestTimeout` 继续约束单次 attempt，并按 retry 剩余预算裁剪。由于请求可能已经到达服务端，
任何超时后的重试都可能产生重复日志，这是 at-least-once 语义的一部分。

`retryTransientHTTPResponses` 开启时，有界重试收到的 408/499 和 400 中结构化标记为 transient
的上传错误；参数错误和未知 400 终止。关闭时回退到 Core 的 429/500/502/503/504 集合。
Objective-C 通过 `retryMaxAttempts`、`retryTotalTimeout`、`retryInitialInterval`、
`retryMaxInterval` 和 `retryTransientHTTPResponses` 一一映射；这些 `TimeInterval` 值的单位都是秒。

内存模式默认 `memoryRetryRetention = 0`，不会跨 retry cycle 保留；设置为正数可在同一有限 buffer
内保留失败批次，但进程退出后无法恢复。`.buffered` / `.sync` 使用 WAL 保留可恢复的重试失败。

以下错误通常不属于可重试范围：

- 明确的认证或授权失败；
- 参数错误；
- 本地无效日志；
- 已确定不可重试的服务响应。

认证失败的数据处理还受 `unauthorizedPolicy` 影响，见[身份认证](authentication.md)。

网络恢复时可调用 `try producer.notifyNetworkRecovered()`（Objective-C 为
`notifyNetworkRecoveredWithError:`）作为提示。该调用会推进仍保留的 transient 失败，不会取消
正在进行的请求，也不会恢复已经丢弃的批次；它不保证后台期间送达。

## Redirect

SDK 只允许不会改变已签名请求目标的 redirect。scheme、host、有效端口、方法、路径、query
或请求体发生变化时会拒绝跟随，并返回 transport 错误。这样可避免把签名头发送到不同目标，
也避免 redirect 后的请求与原签名不一致。

服务使用不同域名、端口或路径时，直接把最终 HTTPS origin 配置为 endpoint；依赖 redirect 会使
请求目标和签名语义发生变化。

## 自定义 URLSessionConfiguration

可以通过 `urlSessionConfiguration` 配置网络策略或测试协议。`ProducerConfiguration` 会复制
配置，并始终清除：

- URL cache；
- Cookie storage；
- credential storage；
- 自动 Cookie 写入。

配置在 `open` 时冻结，后续修改调用方原对象不会热更新 Producer。自定义协议需要保持请求体、
签名头和完成回调的正确语义；记录敏感请求头或完整日志正文会暴露凭据和业务数据。

## 弱网建议

- 使用持久化模式承接离线窗口；内存模式只有显式设置 `memoryRetryRetention` 才跨 retry cycle 保留；
- 保持 `unauthorizedPolicy = .retain`，并及时刷新临时凭证；
- 让 `buffer.fullPolicy = .reject` 保持调用路径可控，业务层按日志重要性降采样；
- 监控 `transport`、`timeout`、`auth`、`quota` 和 `bufferFull`；
- 使用稳定事件 ID 评估恢复后的重复与缺失，而不是只统计发送调用次数。

过短的 `requestTimeout` 会提高不确定结果和重复发送的概率，不适合仅为快速失败而设置。

## 排查信息

排查发送失败时，以下字段有助于定位问题：

- `ProducerError.errorCode`；
- HTTP 状态码（如果是 `service`）；
- Request ID；
- 发生时间、网络状态和 endpoint host；
- 当前持久化与凭证策略。

AK、SK、STS token、Authorization、URL userinfo 或完整请求体不写入排查记录，以免扩大敏感信息
暴露面。
