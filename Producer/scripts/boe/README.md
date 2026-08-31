# Real BOE acceptance helpers

本目录只包含显式 opt-in 的真实 BOE 验收工具，默认命令不会读取凭证或写数据。
调用方必须在进程环境准备 `VE_TLS_ENDPOINT`、`VE_TLS_REGION`、
`VE_TLS_TOPIC_ID`、`VE_TLS_ACCESS_KEY_ID`、`VE_TLS_ACCESS_KEY_SECRET`；工具不会
打印这些值。不要把带凭证的 `.xctestrun`、环境转储或 Simulator launch 环境归档。

## 服务端 Search/Consume 双重校验

`tls_boe_verify.go` 使用官方 Go SDK，对一个唯一 run ID 同时执行：

- `SearchLogsV2`：字段值、数量、序号集合和重复数；
- `DescribeShards + DescribeCursor + ConsumeLogs`：逐分片消费、字段值、时间窗、
  source/file/tags、数量和重复数。

它支持 `field_fidelity`、`large_payload`、`recovery` 三种 profile，以及
`forbid|allow|require` 三种重复策略。ACK 丢失恢复必须使用 `require`，否则不能
声称已证明 at-least-once。

建议从一个已核对 commit、干净的官方 Go SDK checkout 执行：

```sh
GOCACHE=/private/tmp/tls-boe-acceptance/go-cache \
go run -ldflags=-linkmode=external \
  /absolute/path/to/Producer/scripts/boe/tls_boe_verify.go
```

所有 `LOG_SERVICE_*` 和 `BOE_VERIFY_*` 配置均通过环境传入。失败输出只包含稳定
错误类型和计数，不包含凭证、原始响应体或日志 payload。

## 真实 WAL / at-least-once 矩阵

先构建 SimulatorRecoveryHarness，再显式运行：

```sh
TLS_SIMULATOR_DERIVED_DATA_PATH=/private/tmp/tls-boe-acceptance/RecoveryDerivedData \
  Producer/scripts/simulator-recovery/build-simulator.sh

TLS_RUN_REAL_BOE_RECOVERY=1 \
TLS_BOE_SIMULATOR_UDID=<booted-simulator-uuid> \
TLS_BOE_RECOVERY_DERIVED_DATA=/private/tmp/tls-boe-acceptance/RecoveryDerivedData \
TLS_BOE_RECOVERY_EVIDENCE_DIR=/private/tmp/tls-boe-acceptance/evidence/recovery \
  Producer/scripts/boe/run-real-boe-recovery.sh
```

脚本固定执行 `buffered/sync × block-before-send/lose-ack-after-200` 四轮：

1. 每轮卸载并重新安装 App，清空旧 WAL；
2. seed 进程持久化并 admission 三条唯一日志；
3. 等待故障标记后用 `simctl terminate` 建立真实进程边界；
4. recover 进程使用同一 producer ID 和正确网络，要求三条成功回调；
5. 输出不含凭证的 `recovery-runs.tsv` 和三个 JSON 标记。

本地结果不是最终结论。必须再按 TSV 的 run ID、时间窗和重复策略执行
`tls_boe_verify.go`：未发送轮应为三个唯一/零重复；ACK 丢失轮必须三个唯一且至少
一个重复，并且 Search 与 Consume 结论一致。
