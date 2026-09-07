# Volcengine TLS Producer 文档

`VolcengineTLSProducer` 是面向 Apple 平台的异步日志上传 SDK，文档围绕 `v2.0.x` 主线展开。
建议按以下顺序阅读。

## 开始接入

1. [产品概述](getting-started/overview.md)：能力、边界和核心概念
2. [安装](getting-started/installation.md)：SwiftPM、CocoaPods 和版本升级
3. [快速开始](getting-started/quick-start.md)：创建、写入、回调和关闭
4. [验证写入](getting-started/verify-ingestion.md)：从本地接收到服务端查询的验证闭环

Objective-C 项目请参阅 [Objective-C 接入](getting-started/objective-c.md)。

## 场景指南

- [身份认证](guides/authentication.md)
- [持久化与恢复](guides/persistence-and-recovery.md)
- [网络、超时与重试](guides/network-and-timeouts.md)
- [生命周期、App Extension 与 macOS](guides/lifecycle-and-extensions.md)
- [多 Producer](guides/multiple-producers.md)

## API 参考

- [兼容性](reference/compatibility.md)
- [配置参数](reference/configuration.md)
- [日志模型](reference/log-model.md)
- [API 与错误码](reference/api-and-errors.md)
- [隐私说明](reference/privacy.md)

## 运维与迁移

- [故障排查](operations/troubleshooting.md)
- [性能测试](operations/performance.md)
- [v1.x 到 v2.0.x](migration/v1-to-v2.md)

Producer v2 只负责日志上传，不提供查询、消费或管理接口。旧版 v1.x Objective-C 客户端的
入口和兼容边界见[迁移文档](migration/v1-to-v2.md)。
