# SimulatorRecoveryHarness

这是一个只用于验证模拟器进程级 WAL recovery 的最小 iOS App。仓库和 App
包内不包含真实 AK/SK；真实环境运行时只能通过子进程环境注入凭证。默认本地
fixture 仍使用无意义测试凭证。可选的测试专用 `URLProtocol` 只实现
`block-before-send` 和 `lose-ack-after-200` 两种故障，不属于 SDK 生产代码。

App 的固定 bundle ID 是 `com.volcengine.tls.SimulatorRecoveryHarness`。
它通过本仓库根的 Swift package 依赖 `VolcengineTLSProducer`，并固定使用
`producerID`（由脚本传入）。Documents 中的状态、网络标记和结果 JSON 只包含
run ID、场景、计数、模式、状态码和时间戳，不包含 endpoint、凭证或日志 body。

## 测试模式

通过启动参数或同名环境变量选择
`--mode=seed|recover|soak|volume|protection`。
其他配置由 `launchctl setenv` 注入模拟器进程：

| 变量 | 说明 |
| --- | --- |
| `TLS_SIMULATOR_ENDPOINT` | 必填 HTTPS endpoint；不得是 URLProtocol 替身 |
| `TLS_SIMULATOR_REGION` | 必填 region |
| `TLS_SIMULATOR_PROJECT_ID` | 必填 project ID |
| `TLS_SIMULATOR_TOPIC_ID` | 必填 topic ID |
| `TLS_SIMULATOR_PERSISTENCE` | `buffered` 或 `sync` |
| `TLS_SIMULATOR_PRODUCER_ID` | 必填、两次启动必须相同 |
| `TLS_SIMULATOR_RUN_ID` | 必填，用于关联一轮；每条测试日志写入 `run_id` |
| `TLS_SIMULATOR_SCENARIO` | 可选场景名；真实验收时与 run ID/seq 一起写入日志 |
| `TLS_SIMULATOR_NETWORK_FAULT` | `direct`（默认）、`block-before-send` 或 `lose-ack-after-200`；recover 只能是 `direct` |
| `TLS_SIMULATOR_SEED_COUNT` | `seed` 必填；每条为估算 1 KiB |
| `TLS_SIMULATOR_ACCESS_KEY_ID` | 可选；只从进程环境读取，不接受命令行参数 |
| `TLS_SIMULATOR_ACCESS_KEY_SECRET` | 可选；只从进程环境读取，必须与 AK 同时设置 |
| `TLS_SIMULATOR_SECURITY_TOKEN` | 可选；只从进程环境读取 |
| `TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS` | `recover` 等待终态回调的超时，默认 120 |
| `TLS_SIMULATOR_SOAK_DRAIN_TIMEOUT_SECONDS` | `soak` 停止 admission 后等待所有终态回调的超时，默认 30 |
| `TLS_SIMULATOR_SOAK_DURATION_SECONDS` | `soak` 必填；秒 |
| `TLS_SIMULATOR_SOAK_INTERVAL_MS` | `soak` 必填；相邻 admission 间隔 |

额外的 `protection` 模式只用于物理 iOS 设备。它打开 buffered/sync Producer，
完成一条持久化 admission，然后逐个读取 Core 目录内 `.ios-producer.lock`、
`manifest`、`checkpoint`、`lease`、segment 及任何额外普通文件的
`NSFileProtectionKey` 与 excluded-from-backup 属性。只有所有文件都精确为
`completeUntilFirstUserAuthentication`、排除备份且固定五类文件均存在，结果
`Documents/device-protection-result.json` 才写为 `success`。模拟器不能替代这条
证据。

`seed` 打开持久化 Producer，连续 `add(..., mode: .immediate)`；每条事件都带
`run_id`、`scenario`、`persistence` 和唯一 `seq`。所有 admission
返回成功后以原子替换写入 `Documents/simulator-recovery-state.json`，然后保持进程
存活。外部脚本观察到 `seed_ready` 后执行 `simctl terminate`。`recover` 启动同一
已安装 App，重新打开相同 producerID，等待 recovered `SendResult` 数量达到 seed
计数，再原子写入 `Documents/simulator-recovery-result.json`。因此不能用同进程
`close`/`reopen` 代替这条证据链。

恢复结果只有在本次 recover 进程收到的 `SendResult` 满足
`successCount == acceptedLogCount` 且 `failureCount == 0` 时才记为 `success`；
callback 计数器不会跨 seed/recover 进程共享。

真实 BOE 的四轮矩阵由
`Producer/scripts/boe/run-real-boe-recovery.sh` 驱动。该脚本只用
`SIMCTL_CHILD_` 环境把凭证传给一次 `simctl launch` 的子进程，不写入
`launchctl` 全局环境、不把值放入命令行参数，也不把凭证复制到证据目录。

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
