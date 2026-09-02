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

它支持 `field_fidelity`、`large_payload`、`recovery`、`volume` 四种 profile，
以及 `forbid|allow|require` 三种重复策略。`volume` 会按固定算法重建每条 payload，
核对全部序号、字段、timestamp、LogGroup metadata，并可对 hash routing 要求最少
命中分片数和同一 hash slot 的单分片稳定性。ACK 丢失恢复必须使用 `require`，否则
不能声称已证明 at-least-once。

`BOE_VERIFY_EXPECT_SCENARIO` 选择 volume payload/profile；默认也用于核对日志里的
`scenario` 字段。如果调用方为 Instruments 或其他专项运行使用了独立场景名，可再
设置 `BOE_VERIFY_EXPECT_LOG_SCENARIO`，两者会分别校验。run ID 与场景名只接受
ASCII 字母、数字、`_`、`-`，避免把测试元数据带入查询语法。

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

## 真实 BOE 有界大流量矩阵

复用上面的 SimulatorRecoveryHarness 构建产物，显式运行：

```sh
TLS_RUN_REAL_BOE_VOLUME=1 \
TLS_BOE_VOLUME_SIMULATOR_UDID=<booted-simulator-uuid> \
TLS_BOE_VOLUME_DERIVED_DATA=/private/tmp/tls-boe-volume/RecoveryDerivedData \
TLS_BOE_VOLUME_EVIDENCE_DIR=/private/tmp/tls-boe-volume/evidence/<fresh-run> \
  Producer/scripts/boe/run-real-boe-volume.sh
```

矩阵固定串行执行 9 轮、总计 50,448 条，入口速率为 200 logs/s：默认 LZ4、禁压缩
count-seal、buffered+c8、sync+10,000 batch、默认/Unicode 自定义 metadata、256 个
hash key 路由、运行中 credentials/destination 原子替换，以及 512 条 sync WAL 的
鉴权 retain→凭证更新恢复。脚本验证 admission、Core 终态回调、close、字段字节下界
和 uncompressed/compressed 指标，但不会把“客户端回调成功”当成数据完整性证据。

必须逐行读取输出的 `volume-runs.tsv`，再为每个 run 执行 `tls_boe_verify.go` 的
`volume` profile。正常矩阵的 duplicate policy 固定为 `forbid`；hash routing 还需传
`BOE_VERIFY_MIN_MATCHED_SHARDS=8`。只有 Search 与 Consume 都验证完整序号、字段和
零重复后，该轮才算通过。

该脚本面向共享 BOE，所以不主动制造 429，也不执行 22 万条/持久化模式的容量边界。
这些测试必须使用专用 topic，避免影响其他用户。
