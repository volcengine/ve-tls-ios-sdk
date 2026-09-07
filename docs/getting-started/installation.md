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
3. 选择 `2.0.0` 或更高的 `2.x` 版本。
4. 将 `VolcengineTLSProducer` product 添加到需要写日志的 target。

### Package.swift

```swift
dependencies: [
    .package(
        url: "https://github.com/volcengine/ve-tls-ios-sdk.git",
        from: "2.0.0"
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
pod 'VolcengineTLSProducer', '~> 2.0'
```

```ruby
# macOS
platform :osx, '10.15'
pod 'VolcengineTLSProducer', '~> 2.0'
```

执行：

```bash
pod install
```

之后使用生成的 `.xcworkspace` 打开工程。

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

- 新接入 Producer 使用 `v2.0.x`。
- 只修复兼容问题时使用 `~> 2.0` 或 SwiftPM 的 `2.x` 版本范围。
- 升级前阅读 [CHANGELOG](../../CHANGELOG.md)，并在测试环境验证回调、持久化恢复和关闭流程。
- v1.x 与 v2.0.x 的关系见[迁移说明](../migration/v1-to-v2.md)。
