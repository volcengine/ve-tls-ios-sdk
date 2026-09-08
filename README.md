# Volcengine TLS Producer SDK

本仓库提供面向 Apple 平台的 Volcengine TLS 异步日志上传 Producer，当前版本为
`v2.0.1`，提供 Swift 和 Objective-C 接口。支持 iOS、iPadOS 和原生 macOS，提供批处理、压缩、重试、背压和可选
WAL。

旧版 `v1.x` Objective-C 客户端的使用入口和迁移边界见
[v1.x 到 v2.0.x 迁移说明](docs/migration/v1-to-v2.md)。

Producer v2 最低支持 iOS 13、Intel Mac 的 macOS 10.15 和 Apple Silicon Mac 的
macOS 11，要求 Swift 5.8+。

## 安装 Producer v2

Swift Package Manager：

```swift
.package(
    url: "https://github.com/volcengine/ve-tls-ios-sdk.git",
    from: "2.0.1"
)
```

将 `VolcengineTLSProducer` product 添加到 App 或 executable target。

CocoaPods：

```ruby
pod 'VolcengineTLSProducer', '~> 2.0.1'
```

完整步骤见[安装](docs/getting-started/installation.md)。

## 快速开始

以下示例假设业务方的安全凭据提供器已返回 `runtimeCredentials`。长期凭据硬编码到客户端会扩大
泄漏面，生产环境推荐使用临时凭证。

```swift
import Foundation
import VolcengineTLSProducer

let destination = Destination(
    endpoint: "https://tls-cn-beijing.volces.com",
    region: "cn-beijing",
    projectID: "YOUR_PROJECT_ID",
    topicID: "YOUR_TOPIC_ID"
)

let producer = try await Producer.open(
    configuration: try ProducerConfiguration(destination: destination),
    credentials: Credentials(
        accessKeyID: runtimeCredentials.accessKeyID,
        accessKeySecret: runtimeCredentials.accessKeySecret,
        securityToken: runtimeCredentials.sessionToken
    )
) { result in
    print(result.status, result.requestID ?? "-")
}

try producer.add(LogEvent(contents: [
    "event_id": .string(UUID().uuidString),
    "message": .string("hello tls")
]))

try await producer.close(timeout: 5)
```

`add` 成功只表示日志到达本地接收边界；远端结果通过 `SendResult` 回调返回。生产环境应使用
临时凭证，并根据业务可靠性要求选择持久化模式。

## 文档

- [文档首页](docs/README.md)
- [产品概述](docs/getting-started/overview.md)
- [安装](docs/getting-started/installation.md)
- [快速开始](docs/getting-started/quick-start.md)
- [Objective-C 接入](docs/getting-started/objective-c.md)
- [验证写入](docs/getting-started/verify-ingestion.md)
- [配置参数](docs/reference/configuration.md)
- [平台兼容性](docs/reference/compatibility.md)
- [持久化与恢复](docs/guides/persistence-and-recovery.md)
- [故障排查](docs/operations/troubleshooting.md)
- [真机性能数据与测试方法](docs/operations/performance.md)

完整 iOS 示例见 [SwiftExample](Producer/Examples/SwiftExample/README.md)，版本变化见
[CHANGELOG](CHANGELOG.md)。v1.x 与 v2.0.x 的选择和迁移见
[迁移说明](docs/migration/v1-to-v2.md)。

SDK 开发与回归测试见[贡献指南](CONTRIBUTING.md)。

## License

[Apache License 2.0](LICENSE)
