# SimulatorRecoveryHarness

这是一个只用于验证模拟器进程级 WAL recovery 的最小 iOS App。它不包含
真实 AK/SK，也不使用 `URLProtocol`：`TLS_SIMULATOR_ENDPOINT` 必须指向一个
可由模拟器访问的 HTTPS 测试服务，并由外部夹具提供测试 CA 信任。

App 的固定 bundle ID 是 `com.volcengine.tls.SimulatorRecoveryHarness`。
它通过本仓库根的 Swift package 依赖 `VolcengineTLSProducer`，并固定使用
`producerID`（由脚本传入）和无意义的测试凭证 `simulator-test-ak` /
`simulator-test-sk`。Documents 中的状态和结果 JSON 只包含计数、模式、状态码
和时间戳，不包含 endpoint、凭证或日志 body。

## 三种模式

通过 `simctl launch` 的 `--mode=seed|recover|soak` 参数或同名环境变量选择模式。
其他配置由 `launchctl setenv` 注入模拟器进程：

| 变量 | 说明 |
| --- | --- |
| `TLS_SIMULATOR_ENDPOINT` | 必填 HTTPS endpoint；不得是 URLProtocol 替身 |
| `TLS_SIMULATOR_REGION` | 必填 region |
| `TLS_SIMULATOR_PROJECT_ID` | 必填 project ID |
| `TLS_SIMULATOR_TOPIC_ID` | 必填 topic ID |
| `TLS_SIMULATOR_PERSISTENCE` | `buffered` 或 `sync` |
| `TLS_SIMULATOR_PRODUCER_ID` | 必填、两次启动必须相同 |
| `TLS_SIMULATOR_RUN_ID` | 必填，用于关联一轮，不写入日志 body |
| `TLS_SIMULATOR_SEED_COUNT` | `seed` 必填；每条为估算 1 KiB |
| `TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS` | `recover` 等待终态回调的超时，默认 120 |
| `TLS_SIMULATOR_SOAK_DRAIN_TIMEOUT_SECONDS` | `soak` 停止 admission 后等待所有终态回调的超时，默认 30 |
| `TLS_SIMULATOR_SOAK_DURATION_SECONDS` | `soak` 必填；秒 |
| `TLS_SIMULATOR_SOAK_INTERVAL_MS` | `soak` 必填；相邻 admission 间隔 |

`seed` 打开持久化 Producer，连续 `add(..., mode: .immediate)`，所有 admission
返回成功后以原子替换写入 `Documents/simulator-recovery-state.json`，然后保持进程
存活。外部脚本观察到 `seed_ready` 后执行 `simctl terminate`。`recover` 启动同一
已安装 App，重新打开相同 producerID，等待 recovered `SendResult` 数量达到 seed
计数，再原子写入 `Documents/simulator-recovery-result.json`。因此不能用同进程
`close`/`reopen` 代替这条证据链。

恢复结果只有在本次 recover 进程收到的 `SendResult` 满足
`successCount == acceptedLogCount` 且 `failureCount == 0` 时才记为 `success`；
callback 计数器不会跨 seed/recover 进程共享。

`soak` 在给定时长内周期性 admission，停止 admission 后等待所有已接收日志的
终态回调，再写结果文件。只有 observed/success 与 accepted 完全相等且失败数为 0
才通过。

## 构建

```sh
cd Producer/scripts/simulator-recovery
./build-simulator.sh
```

该命令只做 generic iOS Simulator build，设置 `CODE_SIGNING_ALLOWED=NO`，不会
安装或运行 App。

## 运行进程恢复矩阵

默认目标是 `buffered` 50 轮 + `sync` 50 轮。脚本默认拒绝执行，必须显式设置
`TLS_SIMULATOR_RECOVERY_OPT_IN=1`，并且必须提供一个 host-side
`TLS_SIMULATOR_RECOVERY_RELEASE_FILE`。release gate 只能是 `/tmp` 或本仓库
`.build` 目录下的普通非 symlink 文件；脚本每轮 seed 前精确删除它，并在
`simctl terminate` 返回后用同目录临时文件 `mv` 原子创建。

HTTPS fixture 必须观察这个 gate：文件不存在时，对 recovery topic 的请求保持
阻塞或返回 503；文件存在后才返回 200。fixture 的实现和文件监听由网络夹具负责，
本 harness 只控制 gate，不修改 fixture 文件。这样可以让 seed 的 immediate
admission 在 kill 前不被正常 200 提前清空。脚本还会精确校验
`TLS_SIMULATOR_DEVICE_UDID` 对应的设备处于 `Booted`；不使用默认 `booted` 别名。

它会在每轮先卸载并重新安装 App 以清除旧 WAL，然后在同一次安装中按
`seed -> simctl terminate -> gate release -> recover` 执行；恢复阶段不会重新安装，
避免把安装重置误当成进程恢复。

```sh
TLS_SIMULATOR_RECOVERY_OPT_IN=1 \
TLS_SIMULATOR_DEVICE_UDID=<booted-device-udid> \
TLS_SIMULATOR_RECOVERY_RELEASE_FILE=/tmp/volcengine-tls-simulator-recovery.release \
TLS_SIMULATOR_ENDPOINT=https://127.0.0.1:9443 \
TLS_SIMULATOR_REGION=cn-beijing \
TLS_SIMULATOR_PROJECT_ID=test-project \
TLS_SIMULATOR_TOPIC_ID=test-topic \
TLS_SIMULATOR_SEED_COUNT=10 \
TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS=120 \
./run-recovery.sh
```

常用覆盖项：`TLS_SIMULATOR_ROUNDS_BUFFERED`、`TLS_SIMULATOR_ROUNDS_SYNC`、
`TLS_SIMULATOR_ROUND_TIMEOUT_SECONDS`、`TLS_SIMULATOR_SKIP_BUILD=1`。
HTTPS fixture 在 release gate 缺失时必须保持请求无响应；`simctl terminate`
返回且脚本原子创建 gate 后才允许返回 200。不能用快速 503 代替 hold，否则 Core
可能在进程终止前耗尽重试，破坏“恢复未发送 WAL”的前提。

如果测试 HTTPS 服务不可用、没有回调返回或模拟器没有可用设备，脚本明确打印
`BLOCKED` 并以非零状态退出；不会把这种情况记成通过。

## 运行 soak（显式 opt-in）

默认时长为 7200 秒（2 小时），但命令不会自动执行：

```sh
TLS_SIMULATOR_RECOVERY_OPT_IN=1 \
TLS_SIMULATOR_DEVICE_UDID=<booted-device-udid> \
TLS_SIMULATOR_ENDPOINT=https://127.0.0.1:9443 \
TLS_SIMULATOR_REGION=cn-beijing \
TLS_SIMULATOR_PROJECT_ID=test-project \
TLS_SIMULATOR_TOPIC_ID=test-topic \
TLS_SIMULATOR_PERSISTENCE=buffered \
TLS_SIMULATOR_SOAK_INTERVAL_MS=1000 \
./run-soak.sh
```

可用 `TLS_SIMULATOR_SOAK_DURATION_SECONDS` 改成较短的预演时长。脚本还会在
`.build/simulator-recovery-reports/` 写宿主侧 App RSS 采样 TSV；RSS 只作为趋势
证据，不使用固定阈值自动判定。脚本不会使用 `-k` 绕过 TLS 证书验证，也不会
读取或输出任何真实凭证。
