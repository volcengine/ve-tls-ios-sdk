# 开发与验证

用户接入请从[安装](docs/getting-started/installation.md)和[快速开始](docs/getting-started/quick-start.md)
阅读。本页面向修改 SDK 或运行回归测试的贡献者。

## 目录

| 路径 | 内容 |
|---|---|
| `Producer/Sources` | SDK 源码与隐私资源 |
| `Producer/Examples` | 接入示例 |
| `Producer/Tests` | 单元、集成及入口性能测试；不属于 SDK 库产品 |
| `Producer/scripts` | 包消费、符号和依赖校验脚本 |
| `docs` | 用户文档 |

C 依赖的版本、许可证和文件校验清单分别见 `Producer/CORE_VERSION`、
`Producer/THIRD_PARTY_NOTICES` 和 `Producer/CORE_VENDOR_SHA256SUMS`。

## 测试

在仓库根目录运行 macOS 测试：

```bash
swift test
```

使用支持 Swift 6 的 Xcode 时，还可以验证严格并发模式：

```bash
swift test -Xswiftc -swift-version -Xswiftc 6
```

完整包验证需要 Xcode、CocoaPods、Ruby 的 `xcodeproj` gem、Python 3、ripgrep，以及一个
已安装的 iOS Simulator。将工具加入 `PATH` 后执行：

```bash
Producer/scripts/verify-all.sh
```

指定现有模拟器时，设置 `IOS_SIMULATOR_DESTINATION`；纯 Objective-C 集成测试的运行选项见
[测试说明](Producer/Tests/ObjectiveCProducer/README.md)。各脚本开头列出了可用环境变量。
需要显式 opt-in 的 HTTPS 测试默认跳过；`SKIP` 不是执行成功，发布验证时应分别记录。

测试仅使用模拟凭据和响应。不要将真实凭据、请求正文、性能采样、构建目录或测试结果归档提交到
仓库。成功的临时消费者工程默认清理；失败时脚本会打印保留目录供排查。

## 提交变更

- 公开接口发生变化时，同步更新用户文档与 `CHANGELOG.md`；
- 修改发送、持久化、关闭或并发行为时，添加对应的回归测试；
- 修改包结构时，验证 SwiftPM、CocoaPods 和公共模块的外部消费；
- 保留第三方版权与许可证说明；
- 提交前运行 `git diff --check`，确认没有误带生成文件。

性能方法见[性能参考](docs/operations/performance.md)。真实网络、设备生命周期与离线恢复的
测试不能由模拟 HTTP 响应替代。
