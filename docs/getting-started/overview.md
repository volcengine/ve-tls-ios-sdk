# 产品概述

`VolcengineTLSProducer` 为 iOS 和原生 macOS 应用提供高吞吐异步日志写入能力。它在调用方
线程完成本地接收，随后在后台聚合、压缩并发送日志。

## 核心能力

| 能力 | 说明 |
|---|---|
| 异步写入 | `add` 不等待网络响应；服务端结果通过回调返回 |
| 批处理 | 按日志数、原始字节数或等待时间封批 |
| 压缩 | 支持 LZ4，也可关闭压缩 |
| 背压 | 缓冲区满时可立即拒绝或有界阻塞调用线程 |
| 并发发送 | 可配置 1～8 个发送线程 |
| 持久化 | 支持内存、buffered WAL 和逐次同步 WAL |
| 重试 | 对可重试的网络和服务错误执行退避重试 |
| at-least-once | 重试和恢复可能产生重复，不承诺 exactly-once |
| 临时凭证 | 支持 STS token，并可原子更新整组凭证 |
| 动态目标 | 可原子更新 endpoint、region、project 和 topic |
| 结构化结果 | 返回成功/失败、原始/压缩字节数和 Request ID |

## 数据流

```text
LogEvent
   │ add
   ▼
本地校验与接收 ──► 批处理/WAL ──► 压缩与签名 ──► HTTPS ──► TLS Topic
   │                    │                              │
   └─ 同步抛错          └─ 重试/恢复                   └─ SendResult
```

`add` 成功只说明日志达到了所选持久化模式的本地接收边界。只有
`SendResult.Status.success` 表示对应批次收到了服务端成功响应。

## 使用边界

- SDK 只负责写入日志，不提供查询、消费、告警或数据加工接口。
- Producer v2 提供 Swift 和 Objective-C 接口，共用日志上传实现。
- endpoint 仅接受 HTTPS origin，路径、查询、用户信息和 fragment 均不在支持范围内。
- HashKey 采用 32 位小写十六进制半开区间
  `[00000000000000000000000000000000, ffffffffffffffffffffffffffffffff)`。
- 时间戳保留 Unix epoch 毫秒以及该毫秒之后的纳秒余数。
- 交付语义是 at-least-once；调用方如需业务去重，应写入稳定事件标识。

支持的系统、架构和包管理器见[兼容性](../reference/compatibility.md)。
