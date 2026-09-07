# Objective-C 接入

Objective-C 项目可以使用 Producer v2 上传日志，不需要在业务 target 中添加 Swift 源文件。
SDK 内部仍包含 Swift，实现与 Swift `Producer` 共用；它不是旧版 v1.x 客户端的兼容层。

本页适用于 Producer v2.0.0 及后续兼容版本。

## 安装与导入

通过 [SwiftPM 或 CocoaPods 安装](installation.md)。CocoaPods 项目从生成的 `.xcworkspace`
打开。在启用 Clang Modules（`CLANG_ENABLE_MODULES = YES`）的 `.m` 文件中导入公开模块：

```objc
@import VolcengineTLSProducer;
```

无需添加业务 bridging header，也不要导入 SDK 内部的 C Core 或 Bridge 头文件。
工程仍需满足 SDK 的 Xcode 和系统版本要求。Swift 工具链由 Xcode 提供，并不要求业务代码改用 Swift。

SwiftPM 的 Objective-C target 可开启模块和 ARC：

```swift
.executableTarget(
    name: "YourObjectiveCTarget",
    dependencies: [
        .product(name: "VolcengineTLSProducer", package: "ve-tls-ios-sdk")
    ],
    cSettings: [.unsafeFlags(["-fmodules", "-fobjc-arc"])]
)
```

这些编译选项设置在业务的 Objective-C target，不需要修改 SDK 包。使用 Xcode 工程时，启用
Clang Modules 和 Objective-C ARC 对应设置即可。

纯 Objective-C Xcode 工程也需要加载 SDK 使用的 Swift 运行库：保留 CocoaPods 生成的
`ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES`，不要覆盖继承的构建设置。对于手工创建的
工程或命令行 target，检查 `LD_RUNPATH_SEARCH_PATHS` 将 `/usr/lib/swift` 放在应用的
Frameworks 路径之前，并保留 `$(inherited)`。iOS 示例为
`/usr/lib/swift $(inherited) @executable_path/Frameworks`；macOS App 的最后一项改为
`@executable_path/../Frameworks`。系统运行库优先，旧系统再回退到随应用嵌入的兼容运行库，
避免同时加载两套 Swift Concurrency。SwiftPM executable 的链接由 SwiftPM 处理。

## 创建与写入

以下代码放在业务对象的方法中；该对象使用 `@property(nonatomic, strong) TLSProducer *producer;`
保留实例。`runtimeCredentials` 表示业务方安全凭据提供器返回的凭证，不要把长期 AK/SK 写入源码。

```objc
TLSProducerConfiguration *config = [[TLSProducerConfiguration alloc] init];
config.destination = [[TLSDestination alloc]
    initWithEndpoint:@"https://tls-cn-beijing.volces.com"
    region:@"cn-beijing"
    projectID:@"YOUR_PROJECT_ID"
    topicID:@"YOUR_TOPIC_ID"];

TLSCredentials *credentials = [[TLSCredentials alloc]
    initWithAccessKeyID:runtimeCredentials.accessKeyID
    accessKeySecret:runtimeCredentials.accessKeySecret
    securityToken:runtimeCredentials.sessionToken];

// 示例在主队列完成创建，便于业务对象管理实例；add 默认采用内存模式。
config.callbackQueue = dispatch_get_main_queue();
[TLSProducer openWithConfiguration:config
                      credentials:credentials
                     onSendResult:^(TLSSendResult *result) {
    NSLog(@"send status=%ld requestID=%@", (long)result.status, result.requestID);
} completion:^(TLSProducer *producer, NSError *error) {
    if (error) {
        NSLog(@"open error=%@", error.userInfo[TLSProducer.errorCodeKey]);
        return;
    }
    self.producer = producer;
    TLSLogEvent *event = [[TLSLogEvent alloc]
        initWithTimestamp:[NSDate date]
        hashKey:nil
        contents:@{@"event_id": NSUUID.UUID.UUIDString, @"message": @"hello tls"}];
    NSError *addError = nil;
    if (![producer addLog:event mode:TLSAddModeNormal error:&addError]) {
        NSLog(@"add error=%@", addError.userInfo[TLSProducer.errorCodeKey]);
    }
}];
```

创建成功后可以连续调用 `addLog:mode:error:`。不要在每条日志之后关闭 Producer。
应用进入可控停止路径、不再写入时：

```objc
[self.producer closeWithTimeout:5 completion:^(NSError *error) {
    if (error) {
        NSLog(@"close error=%@", error.userInfo[TLSProducer.errorCodeKey]);
        // 保留实例，可稍后再次尝试关闭；不要继续 add。
        return;
    }
    self.producer = nil;
}];
```

## 动态更新

```objc
NSError *error = nil;
BOOL updated = [self.producer updateCredentials:refreshedCredentials error:&error];
// 切换目标使用完整的新 destination；此前已接收日志也按当前目标发送。
BOOL moved = [self.producer updateDestination:newDestination error:&error];
```

分别处理每次调用的返回值。更新凭证应在临时凭证过期前完成，不需要重建 Producer。

## 接口对照

| 操作 | Objective-C 接口 |
|---|---|
| 配置 | `TLSProducerConfiguration` |
| 凭证 | `TLSCredentials` |
| 发送目标 | `TLSDestination` |
| 日志 | `TLSLogEvent` |
| 创建 | `+[TLSProducer openWithConfiguration:credentials:onSendResult:completion:]` |
| 写入 | `-[TLSProducer addLog:mode:error:]` |
| 更新凭证 | `-[TLSProducer updateCredentials:error:]` |
| 更新目标 | `-[TLSProducer updateDestination:error:]` |
| 关闭 | `-[TLSProducer closeWithTimeout:completion:]` |
| 发送结果 | `TLSSendResult` |

## 配置参数

配置默认值、范围和单位沿用 [配置参数](../reference/configuration.md)。Objective-C 将嵌套的
batch、buffer 和 metadata 配置展开为属性，其余字段保持同名：

| Swift 配置 | Objective-C 属性 |
|---|---|
| `batch.maxLogCount` | `batchMaxLogCount` |
| `batch.maxRawBytes` | `batchMaxRawBytes` |
| `batch.linger` | `batchLinger` |
| `buffer.maxBytes` | `bufferMaxBytes` |
| `buffer.fullPolicy` | `bufferFullPolicy` |
| `buffer.blockTimeout` | `bufferBlockTimeout` |
| `metadata.source` | `metadataSource` |
| `metadata.fileName` | `metadataFileName` |
| `metadata.tags` | `metadataTags` |

时间间隔单位为秒，字节限制单位为 byte。`TLSAddModeImmediate` 只触发尽快封批，不同步等待发送。
持久化使用 `TLSPersistenceBuffered` 或 `TLSPersistenceSync`；同步 WAL 和阻塞背压不要在主线程使用。

## 错误处理

SDK 错误使用 `TLSProducer.errorDomain`，数值 `code` 对应 `TLSProducerErrorCode`。
`error.userInfo[TLSProducer.errorCodeKey]` 是与 Swift 一致的稳定字符串，例如 `configuration`、
`bufferFull`、`auth`、`timeout` 和 `closed`。依据域和错误码处理，不要解析 `localizedDescription`。
非 `ProducerError` 的未知错误映射为 `unknown`，不会把原始错误正文透传给业务方；SDK 的
`internal` 错误仍使用对应的 `internal` 错误码。

## 使用约定

- 配置对象用于构造实例，在 `open` 调用时生成快照。调用返回后修改原配置不会更新已有实例。
- 不要在另一个线程读取配置或日志对象的同时修改该对象。
- `add` 和动态更新通过 `NSError` 返回错误；写入成功表示本地接收，不表示服务端送达。
- `open`、`close` 的 completion 和发送结果回调在配置的串行 `callbackQueue` 上执行。
  不要在该队列中同步等待回调；更新 UI 时自行切换到主队列。
- 在实例使用期间保留 Producer。回调引用业务对象时注意 block 循环引用。
- 正常退出时先停止添加日志，再调用异步关闭。关闭成功不保证所有日志已送达服务端。

## 日志与可靠性

日志时间使用 `NSDate`，默认取日志对象创建时间。编码规则与 Swift 一致：Unix 毫秒和该毫秒之后
的纳秒余数；精度受 `NSDate` 的浮点表示限制，不承诺任意整数纳秒的无损表示。

内容使用字符串键值。数字、布尔值和复杂结构请先按业务需要转换成字符串或 JSON，不会隐式转换
成其他字段类型。空字符串值可以保留，空日志或非法字段按整条日志拒绝。

持久化、背压、认证失败处理和重试语义与 Swift 接口相同。持久化实例使用稳定的 `producerID`，
不同活跃实例不要共用同一标识。恢复与重试可能产生重复，建议为日志设置稳定的业务事件 ID。
详见 [持久化与恢复](../guides/persistence-and-recovery.md) 和 [API 与错误码](../reference/api-and-errors.md)。
