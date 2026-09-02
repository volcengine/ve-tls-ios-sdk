# VolcengineTLSProducer 隐私接入说明

## SDK 自身行为

- SDK 不自动采集用户标识、设备标识、崩溃、性能、使用行为或广告数据。
- 只有业务 App 调用 `Producer.add` 时显式提供的日志内容、时间戳、hashKey 及
  Producer 级 source/fileName/tags 才会被持久化并发送到调用方配置的 TLS 目标。
- SDK 不用于 tracking，且不配置 tracking domains。
- persistent Core 使用 `stat` / `lstat` / `fstat` 检查 App container 内 WAL
  文件元数据，因此 SDK Privacy Manifest 声明
  `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1`。

基于上述边界，SDK 自身的 `NSPrivacyCollectedDataTypes` 保持为空。这表示 SDK
不会自行选择或捕获 Apple 定义的数据类型，并不表示业务方传入的日志不会离开设备。

## 业务 App 的责任

集成方必须根据实际写入日志的字段和用途，在适用的 App Privacy / App Store
Connect disclosure、宿主 Privacy Manifest、隐私政策及用户授权流程中声明相应的
数据类型、是否关联用户、用途和 tracking 行为。例如，日志中写入用户 ID、位置、
业务行为或诊断信息时，应分别按该 App 的实际处理方式声明，不能以 SDK 的空
collected-data 数组替代。

SDK 的 SwiftPM/CocoaPods 产物均携带同一份 `PrivacyInfo.xcprivacy`。业务 App 的
签名、App Store Connect 上传、Privacy Nutrition Label 和 App Review 属于集成方
发布流程，不是 SDK 源码发布门禁。
