# 从 v1.x 迁移到 v2.0.x

v1.x 和 v2.0.x 是两条独立版本线：

| 版本线 | 定位 | 公共接口 |
|---|---|---|
| v1.x | 旧版 iOS 日志客户端 | Objective-C |
| v2.0.x | iOS、iPadOS 和原生 macOS 日志上传 Producer | Swift / Objective-C |

v2 不是 v1 API 的原位升级。已有 v1 调用不会因为升级依赖自动获得 Producer 语义，应作为新
接入进行设计和验证。

## 使用旧版 v1.x

旧版 Objective-C SDK 的维护入口为 `legacy/1.x`，可从
[GitHub legacy/1.x](https://github.com/volcengine/ve-tls-ios-sdk/tree/legacy/1.x) 获取：

```bash
git clone --branch legacy/1.x --single-branch https://github.com/volcengine/ve-tls-ios-sdk.git
cd ve-tls-ios-sdk
open -a Xcode VeTLSiOSSDK.xcworkspace
```

切到 `legacy/1.x` 后，也可以在 Xcode 中打开仓库根目录下的 `VeTLSiOSSDK.xcworkspace`；该
workspace 会同时加载旧 SDK 工程和示例工程。已有 v1.x tag 继续保持可用，使用旧版的项目可以
按原 tag 构建和维护。

## 何时使用 v2

适合 v2 的场景：

- 持续、高频异步写入日志；
- 需要批处理、压缩和发送重试；
- 需要本地 WAL 和异常恢复；
- 需要运行时刷新 STS 凭证或切换目标；
- 需要 iOS 与原生 macOS 使用同一 Producer API。

如果业务依赖查询、消费或管理能力，请继续保留对应 v1.x 客户端；Producer v2 只负责日志上传，
不提供这些接口。

## 主要语义差异

| 主题 | 迁移注意事项 |
|---|---|
| 接口语言 | v2 提供 Swift 与 Objective-C 接口，但不兼容 v1 的类名和方法；见 [Objective-C 接入](../getting-started/objective-c.md) |
| 生命周期 | Swift 使用 async open/close；Objective-C 使用 completion，不同步等待网络 |
| 写入成功 | `add` 成功只表示本地接收，远端结果通过 `SendResult` 返回 |
| 批处理 | v2 自动按日志数、原始字节数和 linger 封批 |
| 持久化 | `.buffered` / `.sync` 需要稳定且唯一的 `producerID` |
| 重试 | v2 采用 at-least-once，调用方需处理或去重可能的重复日志 |
| 凭证 | AK、SK、STS token 作为整组原子更新 |
| 目标 | endpoint、region、project、topic 作为整组原子更新 |
| HashKey | 32 位小写十六进制半开区间，不接受全 `f` |
| 时间戳 | 传输 Unix 毫秒和该毫秒后的纳秒余数 |

## 迁移步骤

1. 在新模块或灰度路径中安装 `VolcengineTLSProducer`；
2. 将目标和凭证放入安全配置来源；
3. 定义稳定的事件字段、`event_id` 和时间戳；
4. 选择内存或 WAL 模式，并规划 `producerID`；
5. 接入 `onSendResult`，区分本地接收与远端成功；
6. 实现临时凭证刷新；
7. 在正常退出路径接入 `close(timeout:)`；
8. 通过唯一事件 ID 对比新旧链路的字段、时间和数量；
9. 执行离线、重启恢复、认证过期、背压和大量写入验证；
10. 灰度稳定后再移除旧写入路径。

## 并行灰度

如果迁移期间同时写入新旧链路：

- 为事件增加相同的稳定 `event_id`；
- 使用独立的测试 Topic，避免生产数据重复计费和下游重复处理；
- 分别记录两个客户端的本地接收和远端结果；
- 比较字段编码、毫秒/纳秒时间、唯一数、重复和缺失；
- 一侧失败后立即向另一侧重复写入同一事件会放大重复，除非业务已定义幂等规则。

## 回退

回退前先停止向 v2 写入，并尝试正常 `close`。使用 WAL 时直接删除持久化目录会丢失待恢复数据；
先决定由后续 v2 实例恢复、导出业务补偿清单，还是按数据保留策略明确放弃。

版本变化见仓库根目录 [CHANGELOG](../../CHANGELOG.md)。
