# TLS / SLS 4.3.4 模拟器性能验收夹具

该夹具在同一个 Release iOS App 中分别调用 `VolcengineTLSProducer` Swift 公共
API 和 `AliyunLogProducer` 4.3.4 Objective-C 公共 admission API，用同一台已启动
模拟器、同一个本地 HTTPS 服务和相同 workload 采集可复核原始证据。

它不是 BOE 测试，不读取 `.real_boe_info.env`，只使用无意义的固定测试凭证。服务端
只保留数值计数，不记录请求头、URL、body、request ID 或凭证。

## 固定合同

- 每条日志逻辑大小精确为 1,024 bytes（10 个 ASCII key/value 字段）；对象构造与
  公共 `add` 分别记录 P99，正式 admission gate 只使用 `add` P99。
- LZ4、单 sender、默认 1,024 logs / 1 MiB / 3s batch、64 MiB buffer。
- `memory` 与 buffered `persistent`；100、300 logs/s。
- 本地 TLS 1.2+、HTTP/1.1 keep-alive、固定 5ms 服务端响应延迟。
- 每轮单独安装/启动/终止 App；SLS 4.3.4 的已知 destroy-time UAF 不被伪装成
  lifecycle 通过，SLS 每轮由进程隔离回收。
- P99 add、进程 CPU、进程 RSS 三项分别计算 TLS/SLS 中位数比值，正式门限均为
  `<= 1.20`。

`AliyunLogProducer` 4.3.4 podspec 会排除 arm64 Simulator。夹具只清除该
`EXCLUDED_ARCHS` 包装限制，源码保持 tag 4.3.4 不变。因此这条基线必须标注为
“SLS 4.3.4 source-build”，不能冒充其官方 CocoaPods arm64 Simulator 交付证据。

admission 成功数、终态回调数和真实 HTTP 请求数会独立校验。默认 batching 下一个
请求包含多条日志，所以请求数不等于日志数，夹具不会把它错误地描述为逐条服务端
交付证明。

## 短矩阵（默认）

先启动一台专用 Simulator，再执行：

```sh
TLS_PERF_SIMULATOR_ID=<exact-booted-uuid> \
TLS_PERF_OUTPUT_DIR=<durable-output-directory> \
Producer/scripts/performance/run-comparison.sh
```

默认是 warmup 10s + measurement 30s，2 rates × 2 modes × 2 SDKs × 3 次，
共 24 个独立 App 进程。短矩阵用于发现明显回归，默认不以 1.20 阈值阻断。

快速冒烟可缩为：

```sh
TLS_PERF_SIMULATOR_ID=<exact-booted-uuid> \
TLS_PERF_WARMUP_SECONDS=1 \
TLS_PERF_MEASURE_SECONDS=2 \
TLS_PERF_REPEATS=1 \
TLS_PERF_RATES=100 \
TLS_PERF_MODES=memory \
TLS_PERF_OUTPUT_DIR=<durable-output-directory> \
Producer/scripts/performance/run-comparison.sh
```

## 正式矩阵

正式证据要求 TLS 工作树与 SLS 4.3.4 都 clean，warmup 5m + measurement 30m，
三次重复，总时长约 14 小时：

```sh
TLS_PERF_SIMULATOR_ID=<exact-booted-uuid> \
TLS_PERF_WARMUP_SECONDS=300 \
TLS_PERF_MEASURE_SECONDS=1800 \
TLS_PERF_REPEATS=3 \
TLS_PERF_REQUIRE_CLEAN=1 \
TLS_PERF_ENFORCE_GATE=1 \
TLS_PERF_OUTPUT_DIR=<durable-output-directory> \
Producer/scripts/performance/run-comparison.sh
```

输出包含每轮全部 input-construction/add latency 样本、measurement epoch 内的 host `ps` CPU/RSS 样本、
App 计数、服务端计数、进程终止标记、源码 SHA、Xcode/Simulator 信息、分析结果和
`SHA256SUMS`。不要只把产物放在 `/tmp`；CI 必须上传整个输出目录。

校验整套留证文件时必须从输出目录执行：

```sh
(cd <durable-output-directory> && shasum -a 256 -c SHA256SUMS)
```

CPU/RSS 是 App 进程指标，不是 Producer 内部 buffer 使用量；CPU 同时包含输入对象
构造、SDK admission 与后台发送，不能把它误称为 Core-only CPU。短窗口和共享宿主会
产生噪声，只有固定硬件、空闲宿主、正式窗口和完整三次重复可作为发布 gate。

启用默认 `TLS_PERF_REQUIRE_IDLE_HOST=1` 时，夹具会在构建前、正式运行前和结束后
分别检查平台下载/nsurlsessiond，并采样 CPU idle 与所有磁盘吞吐。默认门限为 CPU
单样本 idle 不低于 65%、5 个样本平均 idle 不低于 75%、4 个磁盘样本中的总吞吐
均不超过 5 MB/s；构建后先等待 10 秒再采样。可通过
`TLS_PERF_HOST_CPU_MIN_IDLE_PERCENT`、`TLS_PERF_HOST_CPU_MEAN_IDLE_PERCENT`、
`TLS_PERF_HOST_DISK_MAX_MEGABYTES_PER_SECOND` 和
`TLS_PERF_HOST_RESOURCE_SETTLE_SECONDS` 覆盖，但正式证据必须记录任何非默认值。

## Intel 断网单机执行

Intel runner 会在断开网络和主机连接后独立执行，因此不能依赖运行时 `pod install`
或在线仓库。使用 `Producer/scripts/performance/prepare-offline-runner.sh` 在打包机上
生成含 TLS/SLS clean checkout、预解析 Pods workspace、固定工具链 metadata 和
全量哈希的归档。归档内的具体启动、状态检查和证据封存步骤见
`OFFLINE_RUNNER.md`。离线 short profile 只执行 24 轮短矩阵，不会自动进入约 14
小时正式矩阵。
