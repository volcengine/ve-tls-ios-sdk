# 生命周期、App Extension 与 macOS

Producer 的可靠性边界由本地接收、持久化模式和退出方式共同决定。生命周期通知只能提供
best-effort 的调度机会，不能替代持久化或正常关闭。

## iOS App

普通 iOS App 中，`automaticLifecycleHandling` 默认是 `true`。SDK 会监听前后台变化，在进入
后台时请求尽快处理当前数据，在回到前台时唤醒发送工作。

这个选项：

- 不会自动关闭 Producer；
- 不保证后台时间足以完成网络发送；
- 不会把 `close` 变成远端全部成功确认；
- 不能覆盖崩溃、强制退出和系统立即结束进程。

可控的终止或切换路径通常先停止新增日志，再调用：

```swift
try await producer.close(timeout: 5)
```

## App Extension

App Extension 中 `automaticLifecycleHandling` 默认是 `false`，避免依赖宿主 App 的生命周期
通知。Extension 的典型完成顺序为：

1. 在扩展任务开始时打开 Producer；
2. 在后台队列完成日志写入；
3. 在系统允许的完成路径中调用 `close(timeout:)`；
4. 使用持久化模式时为 Extension 分配独立 `producerID`；与主 App 并发占用同一目录会触发所有权冲突。

Extension 的执行时间由系统控制，`close` 仍可能没有机会完成。需要恢复的日志可使用持久化
模式，在下次同一 Extension 运行时恢复。主 App 与 Extension 默认使用不同容器，不能仅凭
相同 `producerID` 跨容器恢复；当前配置接口不提供 App Group 或自定义共享目录选项。

## macOS App

原生 macOS 不使用 iOS 的应用生命周期通知，因此：

- `automaticLifecycleHandling` 默认是 `false`；
- 即使设为 `true` 也没有效果；
- 菜单栏应用、GUI App、daemon 和命令行工具的受控退出路径调用 `close(timeout:)`；未调用时本地
  批处理和持久化可能来不及完成。

示例：

```swift
let producer = try await Producer.open(
    configuration: configuration,
    credentials: credentials,
    onSendResult: handleSendResult
)

// 应用运行期间调用 producer.add(...)

try await producer.close(timeout: 5)
```

macOS 命令行 target 可以使用异步入口：

```swift
@main
struct LogUploader {
    static func main() async throws {
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: credentials,
            onSendResult: handleSendResult
        )

        try producer.add(event, mode: .immediate)
        try await producer.close(timeout: 5)
    }
}
```

对于可能被信号或系统直接终止的进程，信号处理器中的异步 `close` 不能作为可靠保证。
`.buffered` 或 `.sync` 配合下一次正常启动时的同一 `producerID` 可提供恢复路径。

## 主线程要求

- `open` 和 `close` 是异步接口；semaphore 或同步等待会阻塞主线程；
- `.sync` 持久化会等待磁盘同步，`add` 放在后台队列可避免主线程等待；
- `.block` 背压会等待缓冲空间，在后台线程调用可避免阻塞 UI；
- 默认 `.reject` 适合要求调用延迟可控的 UI 路径。

## 正常退出顺序

可按以下顺序处理正常退出：

1. 关闭新的业务日志入口；
2. 等待正在执行的 `add` 调用返回；
3. 调用 `close(timeout:)`；
4. 成功后释放 Producer；
5. 超时时保留持久化目录，并在后续启动重试恢复。

多个并发调用者等待同一次 `close` 时会收到相同结果。失败后 Producer 不再接收新日志；再次调用
`close` 可重试本地停止过程。

## 异常退出

- 用户强制结束 App；
- 崩溃或断电；
- 系统在后台时间到期后立即结束进程；
- 命令行进程被不可处理的信号终止。

这些场景下只能依靠在终止前已经达到的本地持久化边界。恢复方法见
[持久化与恢复](persistence-and-recovery.md)。
