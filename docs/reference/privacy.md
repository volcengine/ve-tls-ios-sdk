# 隐私说明

## SDK 自身行为

- SDK 不自动采集用户标识、设备标识、崩溃、性能、使用行为或广告数据。
- 只有宿主应用通过 `Producer.add` 显式提供的日志内容、时间戳、HashKey，以及
  `ProducerMetadata`，才会被本地处理并发送到调用方配置的 TLS 目标。
- SDK 不用于 tracking，也不配置 tracking domains。
- 本地持久化会读取应用容器内文件的时间戳元数据，因此 Privacy Manifest 声明
  `NSPrivacyAccessedAPICategoryFileTimestamp`，理由码为 `C617.1`。

SDK 的 `NSPrivacyCollectedDataTypes` 为空，表示 SDK 不会自行选择或捕获 Apple 定义的数据
类型，不表示调用方传入的日志不会离开设备。

## 宿主应用责任

宿主应用在 Privacy Manifest、分发平台隐私标签、隐私政策和用户授权流程中的声明内容，需要以
实际写入字段和用途为准；集成方负责完成适用声明：

- 收集的数据类型；
- 是否与用户身份关联；
- 使用目的；
- 是否用于 tracking；
- 数据保留和访问控制策略。

SDK 的空 collected-data 数组不能替代宿主应用自己的声明。

## 打包检查

SwiftPM 和 CocoaPods 产物都应携带同一份 `PrivacyInfo.xcprivacy`。发布前应在最终 App bundle
而不是只在依赖源码中确认：

1. manifest 文件存在；
2. plist 格式有效；
3. Required Reason API 声明没有被构建流程丢失；
4. 宿主 App 自身的声明与实际日志字段一致。

应用签名、隐私标签、上传和审核由集成方负责。
