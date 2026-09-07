# 快速开始

下面示例创建一个 Producer、发送带唯一事件 ID 的日志、处理异步结果并安全关闭。

## 1. 创建目标和配置

```swift
import Foundation
import VolcengineTLSProducer

let destination = Destination(
    endpoint: "https://tls-cn-beijing.volces.com",
    region: "cn-beijing",
    projectID: "YOUR_PROJECT_ID",
    topicID: "YOUR_TOPIC_ID"
)

let configuration = try ProducerConfiguration(
    destination: destination
)
```

生产环境推荐使用临时凭证；长期 AK/SK 写入源码或配置文件会扩大泄漏面。

```swift
let credentials = Credentials(
    accessKeyID: runtimeCredentials.accessKeyID,
    accessKeySecret: runtimeCredentials.accessKeySecret,
    securityToken: runtimeCredentials.sessionToken
)
```

`runtimeCredentials` 代表业务方的运行时凭据提供器。长期凭据硬编码到源码会扩大泄漏面，生产环境
推荐使用临时凭证。

## 2. 打开 Producer

```swift
let producer = try await Producer.open(
    configuration: configuration,
    credentials: credentials
) { result in
    switch result.status {
    case .success:
        print("sent requestID=\(result.requestID ?? "-")")
    case .failure:
        print("send failed code=\(result.error?.errorCode ?? "unknown")")
    }
}
```

`open` 可能创建持久化目录并恢复 WAL，因此它是异步接口；同步等待会阻塞主线程，调用应放在
异步或后台路径。

## 3. 写入日志

```swift
let eventID = UUID().uuidString
let event = LogEvent(contents: [
    "event_id": .string(eventID),
    "level": .string("info"),
    "message": .string("hello tls"),
    "retryable": .bool(true),
    "count": .signedInt(1)
])

try producer.add(event)
```

`add` 成功表示日志已在本地被接收，不表示服务端已经写入。服务端结果由
`onSendResult` 回调返回。

需要尽快封批时使用 `.immediate`；它仍然不会等待网络响应：

```swift
try producer.add(event, mode: .immediate)
```

## 4. 更新临时凭证

STS 凭证刷新后原子替换整组凭证：

```swift
try producer.updateCredentials(
    Credentials(
        accessKeyID: newAccessKeyID,
        accessKeySecret: newAccessKeySecret,
        securityToken: newSessionToken
    )
)
```

## 5. 正常关闭

在正常、可控的退出路径中，停止新增日志后调用：

```swift
try await producer.close(timeout: 5)
```

`close` 成功表示本地线程安全停止，不代表全部日志都已经远端送达。崩溃、强制终止或系统
直接结束进程时可能没有机会调用它；持久化模式可用于恢复未确认日志。

下一步阅读[验证写入](verify-ingestion.md)，完成从回调到服务端查询的闭环。
