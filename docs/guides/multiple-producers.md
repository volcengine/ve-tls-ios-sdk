# 多 Producer

大多数应用使用一个长期复用的 Producer。多个实例适用于数据目标、凭证、可靠性策略或资源隔离
确实不同的场景。

## 适合拆分的场景

- 不同数据需要写入不同 Topic；
- 不同租户使用不同凭证；
- 关键日志使用持久化，低价值日志只使用内存；
- 不同业务需要独立的缓冲区、背压和回调处理。

如果只是 endpoint、region、project 和 topic 需要整体切换，可以调用
`updateDestination(_:)`，不一定要创建新实例。

## 资源成本

每个 Producer 都有独立的：

- 内存缓冲区；
- 批处理状态；
- 发送线程；
- 网络会话；
- 持久化目录（如果启用）。

Producer 数量与 `sendConcurrency` 相乘后会直接增加线程、连接、内存和磁盘竞争；按每条日志、每个
页面或每次请求临时创建 Producer 会放大这些开销。

## 持久化 ID

同时运行的持久化 Producer 共用 `producerID` 会产生目录所有权冲突，因此每个实例使用不同的
`producerID`：

```swift
let auditConfiguration = try ProducerConfiguration(
    persistence: .sync,
    producerID: "audit",
    destination: auditDestination
)

let metricConfiguration = try ProducerConfiguration(
    persistence: .buffered,
    producerID: "metrics",
    destination: metricDestination
)
```

相同 `producerID` 的第二个活跃实例会因为目录所有权冲突而打开失败。

## 回调队列

SDK 使用私有串行投递队列保证每个 Producer 的结果串行，并以 `callbackQueue` 作为目标执行
环境。多个 Producer 可以共享一个回调队列，也可以各自使用独立队列。

共享的串行目标队列便于统一排序和统计，但耗时回调会阻塞所有实例的结果分发。即使目标是
并发队列，单个 Producer 的结果仍按串行投递。回调中只做轻量记录，复杂处理应转交其他队列。

## 动态目标的语义

`updateDestination(_:)` 原子替换 endpoint、region、project 和 topic 整组配置。已经在本地接收、
但尚未发送的日志也会使用新目标，属于 current-target 语义。

需要严格隔离旧目标和新目标时：

1. 停止向旧 Producer 写入；
2. 根据业务要求等待其批次回调；
3. 调用 `close(timeout:)`；
4. 使用新的 `producerID` 和目标创建新 Producer。

## 生命周期管理

建议由应用级组件持有 Producer，并显式管理：

- 打开状态；
- 凭证刷新；
- 新日志入口开关；
- 正常关闭；
- 启动后的持久化恢复。

在不可控的对象析构中临时创建异步任务无法可靠等待 `close`，关闭流程应由应用级组件管理。
