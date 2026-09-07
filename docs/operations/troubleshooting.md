# 故障排查

排查时先确定失败发生在哪个边界：`open`、本地 `add`、异步批次回调、服务端查询，还是
`close`。这些阶段的成功含义不同。

## 最小检查清单

1. endpoint 是目标地域的最终 HTTPS origin；
2. region、projectID 和 topicID 属于同一个目标；
3. 临时凭证未过期，并拥有目标 Topic 的写入权限；
4. 当前网络可以访问 endpoint，私网地址只能在对应网络环境使用；
5. 应用长期持有 Producer，没有在写入完成前释放或关闭；
6. 回调中没有执行长时间阻塞操作；
7. 验证查询的时间范围覆盖事件时间，并使用唯一 `event_id` 精确搜索。

## 常见症状

### `open` 抛出 `configuration`

检查错误描述中的字段名，常见原因：

- `destination` 为空；
- endpoint 包含路径、query、fragment、userinfo，或不是 HTTPS；
- 持久化模式没有设置 `producerID`；
- timeout 不是整毫秒、为 0、无穷大或超过上限；
- `maxLogAge` 不是正整数秒；
- 配置初始化后被修改成无效值。

### `open` 抛出 `persistence`

- 同一个 `producerID` 已被另一个活跃实例使用；
- 持久化路径不是目录，或锁文件类型异常；
- 存储空间不足或文件属性设置失败；
- WAL 恢复失败。

先确认旧实例已完成关闭；删除运行中的 WAL 或锁文件会绕过目录所有权检查并破坏恢复数据。

### `add` 抛出 `invalidLog`

错误关联值会列出字段路径。检查：

- `contents` 是否为空；
- key 是否为空或包含 NUL；
- HashKey 是否为 32 位小写十六进制，并且不是全 `f`；
- Double 是否为 NaN/Infinity；
- `utf8Data` 是否为有效 UTF-8；
- 集合嵌套是否超过 32 层。

### `singleLogTooLarge`

单条日志编码后的 key/value 原始字节数超过 `batch.maxRawBytes`。可拆分日志或缩小字段；
`maxRawBytes` 高于 9.5 MiB 会超出 SDK 支持的批次上限。

### `queueFull` / `bufferFull`

说明本地生产速度持续高于发送和确认速度。按顺序检查：

1. 网络、认证或服务配额是否阻塞发送；
2. 回调中是否有耗时操作；
3. 是否创建了过多 Producer 或把 `sendConcurrency` 设置得不合理；
4. 是否应该对低价值日志降采样；
5. 实测后再调整 buffer 和批次参数。

`.block` 会等待内存空间，UI 路径使用它可能阻塞界面；`.reject` 只是不等待内存空间，持久化
仍可能进行磁盘 I/O，尤其 `.sync` 放在后台线程可避免 UI 等待。延迟敏感的 UI 路径可将持久化
日志提交到后台线程。

### 回调为 `auth`

刷新 AK、SK、STS token 整组值，并确认权限和系统时间；只更新 token 或继续使用已过期密钥会导致
认证仍然失败。`unauthorizedPolicy = .retain` 时，更新成功后保留的数据会继续发送。

### 回调为 `transport` 或 `timeout`

- 检查 DNS、TLS 信任、代理、防火墙和网络切换；
- 确认 endpoint 是最终目标，不依赖改变 origin 或签名目标的 redirect；
- 区分连接失败与服务端非成功响应；
- 无条件重新 `add` 已经本地接收的事件会放大重复，原请求可能已经到达服务端。

### 回调为 `service` / `quota`

保留 HTTP 状态码、Request ID、发生时间和 SDK 版本。限流时降低速率并检查服务配额。服务
错误不能只按“网络失败”处理。

### `add` 成功但查询不到

依次确认：

1. 是否收到对应批次的 `.success` 回调；
2. 查询时间范围是否依据事件时间而不是发送时间；
3. 是否在正确的 Topic 查询；
4. 字段名和事件 ID 是否完全一致；
5. `maxLogAge` 和 `expiredLogPolicy` 是否改写或丢弃了过期事件；
6. 动态调用 `updateDestination` 后，事件是否按 current-target 语义去了新目标。

### 出现重复日志

重试和 WAL 恢复允许重复，这是 at-least-once 的正常边界。使用稳定 `event_id` 统计唯一事件，
总命中数包含 at-least-once 重复，单独使用它无法判断丢失。若重复异常增多，检查是否在业务层
对回调失败再次 `add`。

### `close` 超时

超时表示本地关闭未在截止时间内完成，不等于日志已经丢失。Producer 会继续拒绝新写入，调用方
可以稍后再次调用 `close`。持久化模式下保留目录；旧实例仍活跃时用同一 ID 打开新实例会触发
目录所有权冲突。

## 主线程卡顿

以下操作可能增加主线程等待：

- `.sync` 持久化；
- `BufferFullPolicy.block`；
- 在主线程构造特别大的字典或集合；
- 在回调中执行同步 I/O。

`open` 和 `close` 是异步接口；用 semaphore 将它们改造成同步调用会阻塞主线程。

## Redirect 被拒绝

SDK 会拒绝改变 scheme、host、有效端口、方法、路径、query 或请求体的 redirect。最终 HTTPS
origin 直接配置到 endpoint，可避免签名目标变化。

## 提交问题

问题报告建议包含：

- SDK 版本；
- Xcode、Swift、系统版本、设备型号和架构；
- SwiftPM 或 CocoaPods；
- 持久化模式和关键非敏感配置；
- `ProducerError.errorCode`、HTTP 状态码和 Request ID；
- 最小复现步骤；
- 问题发生在 `open`、`add`、回调、查询还是 `close`。

问题报告不附带 AK、SK、STS token、Authorization、完整请求体或敏感业务日志，以免扩大泄漏面。
