# 日志模型

一条日志由时间戳、可选 HashKey 和非空的内容字段组成。

```swift
let event = LogEvent(
    timestamp: Date(),
    hashKey: nil,
    contents: [
        "event_id": .string(UUID().uuidString),
        "level": .string("info"),
        "count": .signedInt(1),
        "sampled": .bool(true)
    ]
)
```

`LogEvent` 是值类型。`add` 在本地接收边界使用事件快照，调用返回后继续修改原变量不会改变
已经接收的数据。

## 时间戳

`timestamp` 类型为 `Date`，默认在 `LogEvent` 初始化时取当前时间。SDK 传输：

- Unix epoch 毫秒；
- 当前毫秒之后的纳秒余数，范围 `0..<1_000_000`。

因此时间不会被无条件截断到整秒或整毫秒。`Date` 本身基于浮点数，实际精度仍受系统时钟和
该时间值可表示精度限制。

如果省略 timestamp，应在 `add` 前立即创建事件，避免把对象构造时间误当成业务发生时间。

## HashKey

HashKey 用于选择写入分区。有效格式是 32 位小写十六进制，范围为半开区间：

```text
[00000000000000000000000000000000, ffffffffffffffffffffffffffffffff)
```

全 `f` 是区间上界，不是合法 HashKey。大写字符、长度不等于 32 或非十六进制字符都会使
整条日志被拒绝。省略 HashKey 时使用 SDK 的默认路由策略。

## 内容字段

`contents` 为空时整条日志会被拒绝。key 的规则为：

- 空 key 会使日志被拒绝；
- 含有 NUL 的 key 会使日志被拒绝；
- 按 UTF-8 字节计入原始大小。

任一字段无效时，整条日志以 `ProducerError.invalidLog` 拒绝，不会部分接收。

## LogValue 编码

| 类型 | 传输字符串 |
|---|---|
| `.string("text")` | 顶层字符串原样写入，不加 JSON 引号 |
| `.signedInt(-1)` | `-1` |
| `.unsignedInt(1)` | `1` |
| `.double(1.5)` | `1.5`；NaN 和 Infinity 会被拒绝 |
| `.bool(true)` | `true` |
| `.null` | `null` |
| `.array(...)` | 紧凑 JSON 数组 |
| `.dictionary(...)` | key 排序后的紧凑 JSON 对象 |
| `.utf8Data(data)` | 以 UTF-8 解码后的文本，不自动 Base64 |

集合中的字符串会按 JSON 规则加引号和转义，顶层 `.string` 与 `.utf8Data` 则保持文本语义。
如果需要传输二进制内容，调用方可先编码成 Base64 或其他文本格式。

集合最大嵌套深度为 32。字符串、集合 key 或 UTF-8 数据含有 NUL 时会被拒绝。

## 大小计算

原始日志大小按每个内容字段的 key UTF-8 字节数加编码后 value UTF-8 字节数计算。它不等同于
Swift 对象内存大小，也不等同于最终压缩请求大小。

这是本地接收时的字段大小口径。`SendResult.rawBytes` 则是 Core 统计的未压缩批次大小，包含
日志编码和日志组元数据，不宜用它反推单条业务字段大小。

单条日志超过 `batch.maxRawBytes` 时抛出 `singleLogTooLarge`。批次 `maxRawBytes` 最大为
9,961,472 字节（9.5 MiB），为服务端 10 MB 请求上限预留编码空间。

## 建议字段

为了验证、追踪重试和业务去重，建议至少包含：

- 稳定唯一的 `event_id`；
- 业务发生时间；
- 日志类型或版本；
- 必要的业务维度。

建议避免写入 AK、SK、STS token、Authorization、密码或其他秘密；这些内容进入日志系统会扩大
敏感信息暴露面。业务字段的敏感信息由调用方识别和处理。
