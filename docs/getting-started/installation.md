# 安装

## 环境要求

- iOS 13.0+，设备架构 arm64
- macOS 10.15+（Intel）或 macOS 11.0+（Apple Silicon）
- Swift 5.8+
- Xcode 14.3.1+

完整的平台声明和验证范围见[兼容性](../reference/compatibility.md)。

## Swift Package Manager

### Xcode

1. 选择 **File > Add Package Dependencies**。
2. 输入 `https://github.com/volcengine/ve-tls-ios-sdk.git`。
3. 选择 `2.0.1` 或更高的兼容版本。
4. 将 `VolcengineTLSProducer` product 添加到需要写日志的 target。

### Package.swift

```swift
dependencies: [
    .package(
        url: "https://github.com/volcengine/ve-tls-ios-sdk.git",
        from: "2.0.1"
    )
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(
                name: "VolcengineTLSProducer",
                package: "ve-tls-ios-sdk"
            )
        ]
    )
]
```

## CocoaPods

在 `Podfile` 中选择与宿主一致的平台。

```ruby
# iOS
platform :ios, '13.0'
pod 'VolcengineTLSProducer', '~> 2.0.1'
```

```ruby
# macOS
platform :osx, '10.15'
pod 'VolcengineTLSProducer', '~> 2.0.1'
```

执行：

```bash
pod install
```

之后使用生成的 `.xcworkspace` 打开工程。

上面的写法需要 CocoaPods Specs 中已有对应版本。如果通过 Git tag 接入，在发布 `v2.0.1`
tag 后使用：

```ruby
pod 'VolcengineTLSProducer',
    :git => 'https://github.com/volcengine/ve-tls-ios-sdk.git',
    :tag => 'v2.0.1'
```

## 验证安装

在目标源码中加入：

```swift
import VolcengineTLSProducer

let metadata = ProducerMetadata()
```

编译目标。如果出现 `No such module 'VolcengineTLSProducer'`：

1. 确认 product 或 Pod 已加入当前 target，而不是只加入工程。
2. CocoaPods 工程从 `.xcworkspace` 打开；单独打开 `.xcodeproj` 不会加载 Pod 依赖。
3. 检查 target 的 deployment target 是否满足最低版本。
4. 清理 DerivedData 后重新解析依赖。

业务 target 的公共导入入口是 `VolcengineTLSProducer`；包内其他模块不属于公共 API。

Objective-C 项目的导入方式和完整使用步骤见 [Objective-C 接入](objective-c.md)。

## 版本选择与升级

- 新接入 Producer 建议从 `v2.0.1` 开始，以包含 CocoaPods module map 修复。
- CocoaPods 的 `~> 2.0.1` 允许 `2.0.x` 补丁升级；SwiftPM 的 `from: "2.0.1"` 允许
  `< 3.0.0` 的兼容升级，需要固定补丁版本时在 Xcode 中选择 Exact Version。
- 升级前阅读 [CHANGELOG](../../CHANGELOG.md)，并在测试环境验证回调、持久化恢复和关闭流程。
- v1.x 与 v2.0.x 的关系见[迁移说明](../migration/v1-to-v2.md)。

### 从 2.0.0 升级到 2.0.1

1. CocoaPods 修改 `Podfile` 为上述版本约束，然后执行 `pod update VolcengineTLSProducer`，
   该命令默认更新 Specs 索引；Git 接入则将 `:tag` 改为 `v2.0.1` 后执行同一命令。
   仅执行 `pod install` 可能继续使用锁定的旧版本。
2. SwiftPM 将最低版本改为 `2.0.1`，在 Xcode 的 **File > Packages > Update to Latest Package Versions**
   中更新，并确认 `Package.resolved` 已解析到所需版本。
3. 检查 `Podfile.lock` 或 `Package.resolved` 中的实际版本，重新编译 App。

这次补丁无需修改业务调用代码或迁移持久化文件。若仍提示找不到
`TLSProducerBridge.modulemap`，见[module map 故障排查](../operations/troubleshooting.md#cocoapods-编译提示-module-map-file--not-found)。

### 请求中的 SDK 版本

Swift 和 Objective-C 接口共用发送路径。`v2.0.1` 在 iOS、iPadOS 和 macOS 的请求中携带：

```http
User-Agent: volc-tls-ios/producer/v2.0.1
```

这里的 `ios` 是 SDK 产品标识，macOS 也使用同一标识。`x-tls-apiversion` 表示服务端 API
协议版本，保持为 `0.3.0`；它不是 SDK 发布版本，也不是所集成 C Core 的 Git tag。
