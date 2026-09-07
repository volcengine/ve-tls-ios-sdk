# 验证写入

仅凭 `add` 返回成功无法判断接入完成；验证应同时覆盖本地接收、批次回调和服务端查询。

## 1. 写入唯一标识

为每次验证生成不会复用的事件 ID：

```swift
let marker = "ios-sdk-\(UUID().uuidString)"

try producer.add(
    LogEvent(contents: [
        "event_id": .string(marker),
        "scenario": .string("quick-start"),
        "expected_count": .signedInt(1)
    ]),
    mode: .immediate
)
```

验证日志不包含 AK、SK、STS token、Authorization 或完整请求体，以免暴露凭据和业务数据。

## 2. 等待终态回调

记录以下字段：

- `status`
- `error?.errorCode`
- `requestID`
- `rawBytes`
- `compressedBytes`

只有 `.success` 表示对应批次收到了服务端成功响应。失败时保留 Request ID 用于排查；凭证不写入
日志。

## 3. 在服务端查询

在日志主题的检索页面中选择覆盖发送时间的时间范围，并用事件 ID 精确检索：

```text
event_id:"ios-sdk-<UUID>"
```

确认：

1. 至少能检索到目标事件。
2. 字段值、时间戳和类型编码符合预期。
3. 使用 at-least-once 模式时允许出现重复，但不应出现字段损坏或部分事件。

也可以使用 [ve-tls-cli](https://github.com/volcengine-tls/ve-tls-cli) 执行查询或消费验证。
具体命令以所安装版本的 CLI 帮助和文档为准；生产凭证写入命令历史会形成持久化泄漏面。

## 4. 批量验证

批量场景应为每条日志写入唯一序号，并在服务端核对：

- 期望唯一事件数
- 实际唯一事件数
- 总命中数及重复数
- 缺失序号
- 首尾时间戳
- 回调成功、失败和未终态数量

at-least-once 允许 `总命中数 > 唯一事件数`，但稳定网络下关闭成功且所有批次回调成功时，
不应缺少已接受的唯一事件。异常终止和恢复测试见[持久化与恢复](../guides/persistence-and-recovery.md)。
