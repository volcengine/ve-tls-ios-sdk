# Objective-C 集成测试

`main.m` 是不含 Swift 源文件的外部 consumer。它只导入 `VolcengineTLSProducer` 公共模块，
通过 URLProtocol 返回本地响应，不需要账号或真实服务端。

请求由 URLProtocol 拦截，不会发送到真实服务。故障响应是协议层模拟，不等同于真实系统
断网、DNS 故障或服务端故障。

脚本验证 SwiftPM 的 macOS consumer；SwiftPM 始终读取当前 worktree。CocoaPods 的两种模式
都从当前未提交 worktree 复制一次性源码快照，快照目录固定含空格，随后验证默认静态库和
静态 framework 的 macOS 运行、iOS Simulator 构建。默认 `POD_SOURCE_MODE=git` 会再通过
源码下载和清理路径安装，并在安装后确认 `TLSProducerBridge.modulemap` 仍存在；设置
`POD_SOURCE_MODE=path` 则用同一快照的 `:path` 接入，不创建 Git commit。两种模式都覆盖
SDK 源码路径和 consumer 工程路径中的空格，纯 SwiftPM probe 不受该模式影响。

运行默认 Git 模式：

```bash
Producer/scripts/verify-objective-c-consumer.sh
```

运行 path 模式：

```bash
POD_SOURCE_MODE=path Producer/scripts/verify-objective-c-consumer.sh
```

要同时运行 iOS consumer，先启动一个 Simulator，然后设置：

```bash
RUN_IOS_SIMULATOR=1 IOS_SIMULATOR_UDID=YOUR_BOOTED_DEVICE_UUID \
  Producer/scripts/verify-objective-c-consumer.sh
```

需要 Xcode、CocoaPods、Git、Ruby 的 xcodeproj gem 和 ripgrep；不在 PATH 中的工具可通过
`POD_BIN`、`RUBY_BIN`、`XCODEBUILD_BIN`、`XCRUN_BIN` 指定。

测试覆盖以下场景，并逐项输出回调和请求计数：

- 写入与生命周期：创建、写入、发送结果、更新凭证和目标、关闭后拒绝写入、非法枚举错误，
  以及原始 protobuf 中的 Unicode、空字符串和时间戳。
- HTTP 401：丢弃策略下终态回调为结构化 `auth` NSError，且不重试。
- HTTP 500 -> 200：断言一次重试后只有一个成功回调。
- 超时与断连：由 URLProtocol 对首个请求分别合成超时和断连，随后断言重试成功。
- 持久化恢复：首个 500 保留待发送数据，正常 close 只验证本地
  关闭成功；重新打开同一 producer ID 后恢复并成功发送。不会把 close timeout 当作日志丢失。

所有回调、请求 body 和计数状态均受锁保护；等待均有明确上限。另验证 `closeWithTimeout:-1`
异步返回 configuration NSError 后，producer 仍可用正常 timeout close。

macOS consumer 在最终 marker 后退出。iOS 条件下通过 `UIApplicationMain` 启动同一 runner，
成功后将本次运行（含新的 `run_id`、`started_at`、`finished_at` 和 `cases`）写入
`Documents/objective-c-result.json`，并保持 app 存活，供 Simulator 检查；验证脚本应在看到
`Objective-C consumer PASS` 后终止该 app。它不替代真实 HTTPS、网络故障和服务端读取验证。

临时工程默认在成功后清理；失败保留并打印路径，便于检查日志。设置 `KEEP_SUCCESS=1` 可保留
成功产物和源码快照。脚本不添加 Swift 占位文件，也不设置私有 SDK 头文件搜索路径。
