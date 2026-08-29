# Intel 离线性能 Runner

该归档是一次性、可搬移的单机测试包。它固定 TLS exact SHA、SLS 4.3.4 exact
tag、预解析的 CocoaPods workspace、Xcode/Simulator/架构合同和全部输入文件哈希。
运行阶段只访问 `127.0.0.1` 的本地 HTTPS fixture，不需要 CocoaPods、Ruby gem、
DNS、BOE 或互联网，也不会读取 `.real_boe_info.env`。

## 运行边界

- 仅支持归档 metadata 中固定的 Intel `x86_64`、Xcode 16.4/16F6、iOS 18.5
  Simulator 和专用 device UUID；最终被测 App Mach-O 必须精确为 `x86_64`。
- `start` 会先校验归档全部文件、两个 Git checkout 的 exact SHA/clean 状态和
  Xcode/Simulator 架构；随后关闭其他 Simulator，只启动固定的 18.5 device。
- runner 与每次结果目录都会创建 `.metadata_never_index`，降低 Spotlight 对源码、
  DerivedData 和高频证据文件的后台索引干扰。
- `short` profile 在运行前静置 5 分钟，并要求 CPU idle 单样本不低于 90%、
  5 次平均不低于 92%、磁盘总吞吐不高于 1 MB/s。任何门禁失败都会停止测试并
  封存失败现场，不会带着污染继续跑。
- `short` profile 固定执行 10 秒 warmup + 30 秒 measurement、2 rates × 2 modes ×
  2 SDKs × 3 repeats，共 24 个独立 App 进程，并启用 TLS/SLS `<= 1.20` 比值门禁。
- 本包不会自动启动 14 小时正式矩阵。短矩阵、功能回归和证据复核完成前，不得把
  本包改造成自动串跑正式矩阵。

## 断网前验收

将 `.tar.gz` 和同名 `.sha256` 复制到 Intel 后，在归档所在目录执行：

```sh
/usr/bin/shasum -a 256 -c <archive>.tar.gz.sha256
/usr/bin/tar -xzf <archive>.tar.gz
cd tls-offline-performance-<profile>-<sha>
./run-offline-performance.sh verify
```

只有归档哈希、runner 全量哈希、Xcode 和 x86_64 Simulator 全部通过后，才可以
断开 Thunderbolt/网络。

## 自主运行与状态

```sh
./run-offline-performance.sh smoke
./run-offline-performance.sh start
./run-offline-performance.sh status
```

sealed `short` 包的 `smoke` 先执行同一包、同一 Xcode 和同一 x86_64 App 构建路径下
的 1 秒 warmup + 2 秒 measurement（memory/100 lps/TLS+SLS），用于断连前验证
runner plumbing；它不属于性能基线。`start` 才执行 sealed profile（short 包为 24
轮）。两者都使用 `nohup` + `caffeinate -dims` 脱离终端运行，断开 SSH 不会终止测试。
不要关机、重启或删除专用 Simulator。结果写在 runner 上级目录的
`tls-performance-<profile>-<UTC>/`，结束时无论通过或失败都会生成：

- `RUN_STATUS.txt`：最终 exit code；
- `controller.log`：控制器完整日志；
- `PARTIAL_SHA256SUMS`：除仍可能在最终瞬间变化的 controller log 外的文件哈希；
- `evidence/SHA256SUMS`：完整成功时由性能夹具生成的权威证据哈希；
- 同目录 `.tar.gz` 与 `.tar.gz.sha256`：便于连接恢复后回传。

若 `status` 返回 `stopped-without-final-status`，说明发生了进程被杀、关机或系统级
中断，不能把残留数据当作通过证据。
