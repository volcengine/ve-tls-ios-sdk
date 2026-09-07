# 持久化与恢复

持久化用于在进程异常退出、设备重启或长时间离线后恢复尚未确认的数据。它提供
at-least-once 交付基础，不提供 exactly-once。

## 模式选择

| 模式 | 本地接收边界 | 是否需要 `producerID` | 主要取舍 |
|---|---|---:|---|
| `.disabled` | 内存 | 否 | 开销最低；进程退出后不可恢复 |
| `.memory` | 内存 | 否 | 与 `.disabled` 相同的持久性语义，用于显式表达内存模式 |
| `.buffered` | 缓冲 WAL | 是 | 吞吐较高；突然断电时最近写入仍有缓冲窗口 |
| `.sync` | 每次接收等待 WAL 同步 | 是 | 本地持久性最强；调用延迟和磁盘开销更高 |

`.sync` 会阻塞调用线程直到本地同步完成；`add` 放在业务串行队列等后台路径可避免阻塞 UI。

## 配置示例

```swift
let configuration = try ProducerConfiguration(
    persistence: .buffered,
    producerID: "main-app",
    destination: destination
)
```

`producerID` 的允许字符为 `[A-Za-z0-9._-]`，最多 64 个 UTF-8 字节，`.` 和 `..` 无效。持久化
恢复依赖同一个业务数据流在重启后继续使用相同 ID。

## 目录与所有权

SDK 在当前进程可用的用户域 Application Support 下创建独立目录，并设置备份和文件保护
属性。一个持久化目录同一时间只能由一个活跃 Producer 实例持有。

默认目录位于当前用户的 Application Support 下：

```text
~/Library/Application Support/com.volcengine.tls/producer/<producerID>/
```

iOS 和沙盒化 macOS App 的实际路径位于各自容器；非沙盒 macOS 程序使用当前用户的
Application Support，因此不同程序也应避免复用相同 ID。iOS 额外应用 Data Protection；
macOS 不使用 iOS 的文件保护属性。SDK 会将持久化内容排除在系统备份之外。

以下操作会破坏目录所有权或数据隔离：

- 同时启动两个具有相同 `producerID` 的实例；
- 手动编辑、复制或删除运行中的 WAL 文件；
- 在不同账号、不同数据保留策略或互不信任的业务流之间复用 `producerID`。

如果第二个实例无法取得目录所有权，`open` 会抛出 `ProducerError.persistence`。

## 恢复流程

重新创建 Producer 时同时满足以下条件，SDK 会恢复本地待发送数据：

1. 使用原来的 `producerID`；
2. 使用持久化模式；
3. 应用容器中的持久化目录仍存在；
4. 提供可用凭证和目标配置。

```swift
let recovered = try await Producer.open(
    configuration: try ProducerConfiguration(
        persistence: .buffered,
        producerID: "main-app",
        destination: destination
    ),
    credentials: currentCredentials,
    onSendResult: handleSendResult
)
```

恢复发生在 `open` 期间，可能涉及目录检查和 WAL 扫描；同步等待会阻塞主线程，调用应放在异步
或后台路径。
恢复批次使用重新打开时提供的当前凭证和目标；WAL 不用于固定历史目标。

## at-least-once 边界

以下窗口可能产生重复日志：

- 服务端已接收请求，但客户端未收到响应；
- 请求超时后重试；
- 进程在远端成功与本地确认之间异常退出；
- WAL 恢复后重新发送未确认批次。
- WAL 已写入，但后续内存入队或同步落盘失败，调用方在 `add` 抛错后重新提交同一事件。

为需要业务去重的事件写入稳定的 `event_id`。服务端查询时同时统计总命中数和唯一事件数。

`add` 成功不等于远端成功；`close` 成功也不等于所有日志已经送达。持久化批次在当前实例
关闭后可能留在 WAL，并由后续实例恢复，因此旧实例的回调不保证收到这些批次的最终结果。

### `add` 抛错后是否还会发送

有可能。持久化模式先写 WAL，再完成内存入队。如果后续遇到 `bufferFull`、等待超时、
存储同步失败，或者写入过程中发生 `close`，本次 `add` 可能抛错，但已经写入的记录仍会保留。
只有 WAL、没有内存发送任务的记录，需要使用相同 `producerID` 重新 `open` 才会恢复；
这类记录不会在当前实例中自动重新入队。

因此，收到这类错误不等于“日志肯定没有保存”。重试时应沿用同一个业务 `event_id`，
在消费侧处理潜在重复。前置校验产生的 `invalidLog`、`singleLogTooLarge` 不进入 Core，
不属于这个窗口；对已经关闭的实例调用 `add` 也会在写入前拒绝。

## 缓冲区满

持久化不能消除内存背压。`BufferConfiguration.fullPolicy` 支持：

- `.reject`：不等待内存空间，抛出 `bufferFull`。持久化模式仍可能已经写入 WAL；
- `.block`：等待空间，最多等待 `blockTimeout`；在后台线程使用可避免阻塞 UI。

持续离线或长期认证失败会使待发送数据继续占用缓冲；业务层可根据日志重要性降采样、停止非关键
日志或扩展缓冲区，避免无限等待。

## 验证恢复

可在独立测试主题中验证恢复：

1. 离线写入一组带连续序号的事件；
2. 在写入过程中异常结束进程；
3. 用相同 `producerID` 重新打开；
4. 恢复网络并等待批次终态；
5. 在服务端核对唯一序号、重复数和缺失序号；
6. 再执行一次正常 `close` 和重新打开，确认没有目录占用错误。

正常应用生命周期的处理方式见[生命周期与 App Extension](lifecycle-and-extensions.md)。
