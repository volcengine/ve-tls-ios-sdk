# iOS 内部诊断日志回调验收记录

本工作区已实现文本 `diagnosticHandler`，应用可直接在回调中调用自己的文件 logger。复用原 `onDiagnostic` 与 Core 事件源；诊断共享每实例的独立 1024 条有界队列，文本使用等级过滤与最多 4096 bytes 的单行 JSON。只读统计每 60 秒输出，受控关闭前另输出汇总。

原始实施分支：`feat/ios-delivery-policy-alignment`；内部交付分支：`feat/ios-delivery-policy-alignment-internal`，以内部 `master` 为提交基线。实施前 Git 基线：`8b8a142d3c20a60f0b4a72ed7fd79c991a0b4976`。已有交付策略与诊断增量一并纳入功能分支，提交范围以 Git 记录为准。当前源码版本为待发布的 2.0.2；已发布 2.0.1 不含新接口，当时 Core 状态为 `UNRELEASED_INTEGRATION`；当前来源和候选/标签状态以 `Producer/CORE_VERSION` 为准。

业务基线是开始本任务时的交付策略工作区，并非 Git HEAD 的原始 2.0.1。Core 基线已从原已登记补丁重建，位于 `/tmp/tls-ios-diagnostic-business-baseline/core`。独立只读复核和 owner 检查确认，本次增量只观察原动作；未调整请求载荷、签名、批次、并发、分类、请求超时、尝试计数、退避、预算或 WAL 决策。

## 2026-10-15 文本字段精简增量

按最新需求，文本 formatter 不再输出所有字段的 null 占位；缺失、空值与无信息默认标记省略，`fields_omitted` 仅在为 true 时出现。实际有语义的 0/false（无 HTTP 响应、不可重试、零统计、关闭的生命周期/保留配置等）仍保留。结构化 `onDiagnostic`、事件源、队列、上传、重试及 WAL 决策均未改变。原有 schema_version=1 的字段改为按事件可选输出。

新增/更新了稀疏字段、默认标记白名单、零值/false 与结构化 DTO、脱敏和 4 KiB 回退测试。完整 SwiftPM 回归：382 用例，0 failures，4 skipped；日志 `/tmp/tls-ios-sparse-formatter-build/full-sdk-tests.log`。真机实际回调样例仍为 13 行，26,574→5,833 bytes（约减少 78%），无 null 字段；本轮完整真机重跑结果与业务对照另存验收产物，未以编译通过代替运行。

## 2026-10-15 文本限频最终验收

文本在原 emitter 的私有 drain 队列执行限频，不新增队列、timer、Core 事件或业务调用。
按实例单调时钟滚动 60 秒，Debug/Info 为 30 条/32 KiB，Warning/Error 独立 30 条/32 KiB，
字节包含一字节换行，不含 App logger 自加前缀。重复故障按稳定指纹最多输出一次，窗口从上次
实际输出开始计时，持续重复不会无限推迟下次输出；指纹表最多 128 项。条数满或重复时跳过 JSON
格式化。抑制计数通过下一条实际输出文本的 `text_suppressed_total` /
`text_suppressed_since_last_report` 报告，不更改 typed `onDiagnostic`，不混入业务/FIFO 丢弃计数。

| 本轮执行 | 结果 |
| --- | --- |
| 完整 `swift test --scratch-path /tmp/tls-ios-sparse-formatter-build` | 391 项，0 failures，4 skipped；Transport 41、Integration 80、Persistence 37、Contract 191、Bridge 42 |
| emitter / formatter 针对性测试 | 20 / 11 项通过；覆盖 1440 个一分钟窗口模拟 24 小时故障、窗口不滑动、UTF-8 字节、等级额度隔离、慢回调、指纹有界与格式化失败 |
| 最新签名 App 真机运行 | iPhone 11 Pro Max / iOS17.5.1；26 项全部通过，2026-10-15T12:50:36.737Z 至 12:51:53.045Z |
| 同业务配置原回归 off/on | 各 53 请求、25 个业务观察，原始载荷字节、顺序和终态一致，0 个业务差异 |
| 公开 SDK 重复错误突发 | 各触发 2000 次无效入队；on 收到 2000 条结构化拒绝、1 条拒绝文本，汇总抑制 1999 条；全部文本 12 条/5981 bytes，含换行 |
| 公开 SDK 连续成功突发 | off/on 各 40 请求/40 成功回调，逐请求载荷和顺序一致；on 收到 245 条结构化事件，文本限制为 30 条/15094 bytes，含换行 |
| 最新生成头编译 | `arm64-apple-ios13.0` 下的 NSInteger/NSString block 语法检查通过；不等同完整最低系统构建/运行 |
| 签名及范围 | `codesign --verify --deep --strict` 通过；Core、Bridge、Transport、上传/重试/WAL 源码均未变更 |

证据在工作区 `docs/research/evidence/2026-10-15-ios-v202-device-functional/diagnostic-text-rate/`；
完整命令、文件哈希、源码 patch、实际 App 与生成头一并保留。内部基线 `44ea2c5`，公开候选基线
`a0f84c0`，以上为提交前的验收基线；最终提交与推送状态以 Git 记录为准，两个工作区的同范围文件内容相同。

App 仍应配置自己的文件总容量，例如 2 MiB × 3 个文件循环覆盖；SDK 的限频不能代替文件轮转。
配额按实例计算，反复重建实例会重新计额；App 自行把 typed `onDiagnostic` 写盘时应自行限频。
本轮未重复 CocoaPods 全矩阵、真实跨进程 WAL/人工 UIKit 生命周期，也未新增最低 iOS13/macOS10.15
运行证据。原始真实 HTTPS 成功入库仍未验证，4 个真实网络 opt-in 回归依旧 skipped。

以下原始执行记录保留为字段精简前的业务基线；其中“null”描述的是旧文本占位或原生采样字典，新文本按上述规则省略。最低 iOS 13/macOS 10.15 的完整运行、真实 HTTPS 入库等既有验证边界不因本次格式优化而扩大。

## 客户使用方式

在 `open` 之前设置回调，才能接收初始化失败。SDK 不写文件，路径、轮转、输出级别和 fsync 由 App 的 logger 决定。

```objc
config.diagnosticLogLevel = TLSProducerDiagnosticLogLevelInfo;
config.diagnosticHandler = ^(NSInteger level, NSString *message) {
    BXLogI(@"[VolcTLS-SDK][terminal] %@", message);
};
```

双 handler 同时配置时，每条已准入事件先调用结构化回调，再按等级和限频规则决定是否调用文本回调。文本 Off 不影响结构化回调。慢回调延迟诊断并可能丢弃诊断；它不阻塞发送结果或 close。客户不能把诊断重新 add 到同一个 Producer，也不应在回调内同步等待 SDK 操作。

## 执行结果

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 完整 SwiftPM SDK 回归 | 379 用例，0 failures，4 skipped | `/tmp/tls-ios-diagnostic-final-tests.log`；Transport 41、Integration 80、Persistence 37、Contract 179、Bridge 42 |
| Core 独立完整 CTest | 13/13 通过 | `/tmp/tls-ios-diagnostic-core-final-tests.log` 与 `/tmp/ve-tls-c-sdk-diagnostic-build/Testing/Temporary/LastTest.log` |
| Objective-C 实际生成头 + 真实 SDK 运行 | off/on 各 6 个业务用例通过；各 10 请求、6 发送回调 | `/tmp/tls-ios-diagnostic-objc-off.log`、`/tmp/tls-ios-diagnostic-objc-on.log` |
| App FILE logger 文本回调 | 106 行、7 个实例，最大 2122 bytes 的 JSON 已实际写入文件；序列、等级、容量与脱敏检查通过 | `/tmp/tls-ios-diagnostic-callback.jsonl`、`/tmp/tls-ios-diagnostic-callback-validation.json` |
| iOS 13 Objective-C 生成头编译 | 通过，使用实际 device 构建生成的 Swift header 与纯 ObjC 夹具 | `/tmp/tls-ios-diagnostic-header13-check.log` |
| iOS 15 device / simulator、Swift 6 编译 | 两项通过 | `/tmp/tls-ios-diagnostic-device-build.log`、`/tmp/tls-ios-diagnostic-simulator-build.log` |
| Core vendor / patch / SHA256 / 文件集校验 | 通过，校验 Git base + 登记补丁的重构结果 | `/tmp/tls-ios-diagnostic-vendor-check.log` |
| 最终 SDK 静态库 public symbols | 通过，无 Core/LZ4 公开符号泄露 | `/tmp/tls-ios-diagnostic-symbol-check.log` |
| 完整 iOS 13 SDK 编译 | **未完成**：工具链支持范围是 iOS 15..27 | `/tmp/tls-ios-diagnostic-ios13-build.log`；未修改产品最低 iOS 版本 |
| CocoaPods 外部纯 ObjC 集成 | **当前工具链目标通过**：macOS12/iOS15，静态库和 static framework 4/4 构建；两个 macOS 客户端实际运行/on-off 文件回调通过。最低 macOS10.15/iOS13 仍未验证 | `/tmp/tls-ios-cocoapods-validation/results.json`、`/tmp/tls-ios-cocoapods-current-sdk-integration.log` |
| iOS Simulator 运行预检 | **未完成**：最新 xcodebuild 确认 CoreSimulator 1051.55.0 低于要求的1171.7.0，并存在 CoreDevice 符号不匹配；之前设备枚举已中止 | `/tmp/tls-ios-cocoapods-current-sdk-integration.log`、`/tmp/tls-ios-diagnostic-simulator-runtime-status.json` |
| 真实 HTTPS redirect 回归 | **未执行**：现有 4 个 opt-in 用例 skipped | 启用条件 `TLS_RUN_REAL_REDIRECT=1`，不标为通过 |

## D01–D21 证据矩阵

下表“通过”指已执行的受控、真实 SDK 或 Core 夹具范围；不将 macOS 运行扩大解释为 iOS 真机验收。

| 编号 | 状态 | 已执行证据 |
| --- | --- | --- |
| D01 | 通过 | `testSwiftDefaultsAreDisabledAndTextOffDoesNotEnableEmitter`、`testDisabledEmitterIsNoOpAndDoesNotInvokeCallbacks`；实际 SDK off/on 业务对照；禁用路径不创建 sampling timer/sink |
| D02 | 头文件合同通过 | 真实生成头的 NSInteger/NSString copy nullable block、enum 0..4；arm64 iOS 13 Clang syntax compile 通过。完整 iOS 13 SDK/运行不标通过 |
| D03 | 通过 | `testStructuredThenTextShareSequenceAndSnapshotContext`、`testTextLevelThresholdLeavesStructuredDeliveryIndependent`；真实 ObjC 文本文件回调 |
| D04 | 通过 | 等级逐项/Off 测试与稳定等级映射；过滤只位于 emitter 文本分支；结构化与业务不随 threshold 改变 |
| D05 | 通过 | `testOpenSnapshotsDiagnosticHandlersAndLevel`、`testTwoOpenInstancesKeepDiagnosticEventsAndInstanceIDsSeparate` |
| D06 | 通过 | missing destination、非法 endpoint、凭证校验、目录文件冲突、native lease 构造失败；每路径一个 open_failed，初始化前 instance_id 已存在 |
| D07 | 通过可达路径 | ObjC 未支持 mode、not-ready、invalidLog、singleLogTooLarge、queueFull、bufferFull、closed 的原错误/阶段/单次计数。`TLSLogEvent.swiftValue()` 当前不抛错，`facade_log` 转换失败不可达，未伪造该路径 |
| D08 | 通过 | 多线程 24 accepted + 8 rejected 分类计数；实际 60 秒 timer 汇总和受控关闭汇总；native 无值使用 null；Core 与 Facade 不重复求和 |
| D09 | 通过 | 单日志未达阈值无请求、无 sealed/started；关闭才发送。60 秒汇总也未 flush 未达阈值业务批次 |
| D10 | 通过 | 实际 SDK on/off：200、400 InvalidArgument、400 ClientCanceled、408、429、500/503、URLSession timeout/network lost；同请求序列与 SendResult；Core fake clock 的 sleep/cap/预算对照 |
| D11 | 通过 | 最大尝试、预算/准备期间耗尽、memory retention 关闭/开启/到期/close、WAL retained 的现有真实 Core/SDK 回归；disposition 来自实际分支。elapsed 冻结于请求结束；下一非 HTTP 尝试 ID/time/queue wait 清空 |
| D12 | 通过 | 固定业务时间的 SDK请求：URL/body/压缩/非实时头相等；只排除 Authorization/X-Date。Core fake clock **完整头/签名输入**、请求顺序与超时上限相等；没有诊断请求字段 |
| D13 | 通过 | emitter 阻塞后准入 1024、再 32 条计 drop；真实 SDK 阻塞文本 handler、制造 1100 次拒绝时请求、SendResult、close 仍完成；恢复后 drop 汇总 |
| D14 | 通过 | `testWallClockRegressionPreservesOccurrenceTimeAndDiagnosticDurations` 的墙钟 200→100 / sequence 1→2 / 非负耗时；多线程 300 事件 FIFO sequence，受控 clock，JSON/长字段/UTF-8≤4096；真实文件实例内序列严格递增 |
| D15 | 通过 | Core 0..3 保持原映射，4→batchSealed/10、5→attemptStarted/11；unknown 独立保留 |
| D16 | 通过 | typed 字段白名单、敏感文本/URL/凭证/正文不进入回调和 DTO description；合法完整 RequestID、非法/超长 null；关联 128/30s 过期后不能回退旧 normalized ID |
| D17 | 通过 | SDK deadline、URLSession timeout、显式 cancel、invalidate、unknown -999 的真实 Transport 夹具；一请求一个原终态，不改 retryable |
| D18 | 通过受控 metrics | 实际 Transport context/delegate 上注入 partial bytes、连接复用、缺失/迟到 metrics，128 条/30 秒上限；即时提取标量，不等待 metrics。真实网络各阶段数值未另作真机实测 |
| D19 | 受控通过；移动端未完成 | mock lifecycle host/通知观察已有 foreground/background/expiration，extension 静默、后台任务配对不变；Swift 6 iOS 编译通过。iOS 真机/模拟器运行另列环境限制 |
| D20 | 通过受控范围 | 慢结构化/文本 handler 下 close 完成；close timeout、native getter 与生命周期锁、dealloc/inflight 现有回归；独立复核无引用环/UAF 问题。未宣称完成真机压力测试或额外 sanitizer 验收 |
| D21 | 通过受控范围 | disabled/buffered/sync 回归、成功 ACK 后文件集合/空恢复一致；Core fake clock off/on durable ACK 一致；`testProducerPersistentAdmissionDiagnosticsTogglePreservesReplayAndWAL` 验证 valid add bufferFull 后 WAL 恢复的 buffered/sync off/on，同 producerID/payload/time，文件集合明确为 manifest/checkpoint/seg-000001.log |

## on/off 行为对照

- 实际 SDK：HTTP成功、HTTP重试、不可重试 400、暂态 400/408/429/5xx、本地 timeout/network lost、最大尝试终态的请求次数、次序、URL、payload、压缩、非实时签名头与发送结果相同。
- 签名包含实时 X-Date，SDK实时时钟夹具不盲比 Authorization。Core fake clock 夹具另比较完整 headers/签名输入、retry sleep `[3]`、request timeout cap、terminal result、memory retained 和 WAL ACK，结果一致。
- 纯 ObjC 同一配置 off/on：6 用例、10 请求、6 个发送结果回调，结果相同。诊断开启额外产生 SDK 诊断 callback，不进入业务载荷。
- WAL 成功后的空恢复无重复请求；buffered/sync 文件集合一致。诊断不能将 add bufferFull 推断为 discard，因为原路径可能已追加 WAL。
- 诊断的 Core metrics 与 buffer 水位是分别读取，报告不声称原子快照；诊断采集不在 Core 回调持锁内调用 buffer getter。

## 可复核命令

命令在 SDK 仓库根运行。WAL 测试需允许夹具使用随机 App Application Support 目录；网络均用本地 URLProtocol。

```sh
swift test --package-path Producer --scratch-path /tmp/tls-ios-diagnostic-build
ctest --test-dir /tmp/ve-tls-c-sdk-diagnostic-build --output-on-failure
VE_TLS_CORE_SOURCE_ROOT=/Users/bytedance/workspace/src/sdk/ios_with_producer/ve-tls-c-sdk-ios-delivery-alignment bash Producer/scripts/verify-core-vendor.sh
bash Producer/scripts/verify-public-symbols.sh /tmp/tls-ios-diagnostic-build/out/Products/Debug/libVolcengineTLSProducer.a
swift build --disable-sandbox --package-path Producer --scratch-path /tmp/tls-ios-diagnostic-device-build --triple arm64-apple-ios15.0 --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk -Xswiftc -swift-version -Xswiftc 6
swift build --disable-sandbox --package-path Producer --scratch-path /tmp/tls-ios-diagnostic-simulator-build --triple arm64-apple-ios15.0-simulator --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk -Xswiftc -swift-version -Xswiftc 6
xcrun --sdk iphoneos clang -fsyntax-only -fobjc-arc -fmodules -Werror=incompatible-pointer-types -target arm64-apple-ios13.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk -fmodules-cache-path=/tmp/tls-ios-diagnostic-header13-cache -fmodule-map-file=/tmp/tls-ios-diagnostic-device-build/out/Intermediates.noindex/GeneratedModuleMaps-iphoneos/VolcengineTLSProducer.modulemap -fmodule-map-file=/tmp/tls-ios-diagnostic-device-build/out/Intermediates.noindex/GeneratedModuleMaps-iphoneos/TLSProducerBridge.modulemap -I Producer/Sources/TLSProducerBridge/include Producer/Tests/ObjectiveCProducer/main.m
xcrun clang -c -fobjc-arc -fmodules -fmodules-cache-path=/tmp/tls-ios-diagnostic-objc-cache -fmodule-map-file=/tmp/tls-ios-diagnostic-build/out/Intermediates.noindex/GeneratedModuleMaps/VolcengineTLSProducer.modulemap -fmodule-map-file=/tmp/tls-ios-diagnostic-build/out/Intermediates.noindex/GeneratedModuleMaps/TLSProducerBridge.modulemap -I Producer/Sources/TLSProducerBridge/include Producer/Tests/ObjectiveCProducer/main.m -o /tmp/tls-ios-diagnostic-objc-fixture.o
xcrun swiftc /tmp/tls-ios-diagnostic-objc-fixture.o /tmp/tls-ios-diagnostic-build/out/Products/Debug/libVolcengineTLSProducer.a -o /tmp/tls-ios-diagnostic-objc-fixture
/tmp/tls-ios-diagnostic-objc-fixture
TLS_OBJC_DIAGNOSTICS=1 TLS_OBJC_DIAGNOSTIC_FILE=/tmp/tls-ios-diagnostic-callback.jsonl /tmp/tls-ios-diagnostic-objc-fixture
SKIP_IOS=1 KEEP_SUCCESS=1 POD_SOURCE_MODE=path bash Producer/scripts/verify-objective-c-producer.sh
```

## 修改文件与产物

本轮诊断文件清单遵循实现合同：

- Swift：`ProducerConfiguration.swift`、`ProducerDiagnostic.swift`、`Producer.swift`、`ObjectiveC/TLSProducerFacade.swift`、`Core/{CoreAdapter,RealCoreAdapter}.swift`；新增 `Diagnostics/{DiagnosticEmitter,DiagnosticFormatter}.swift`。
- Bridge：`Core/TLSRealCoreAdapter.{h,m}`、`Transport/{TLSHTTPRequest,TLSTransport}.{h,m}`、`Transport/TLSHTTPResponse.h` 的 delegate 声明、`Lifecycle/TLSLifecycleManager.{h,m}`。
- Core：`include/ve_tls_producer.h`、`core/src/ve_tls_producer.c`、`core/src/producer/{ve_tls_producer_internal.h,ve_tls_producer_manager.c,ve_tls_producer_sender.c}`；对应独立 Core `tests/test_basic.c` 测试纳入补丁。
- 配套：`CORE_VERSION`、`CORE_VENDOR_SHA256SUMS`、`core-patches/delivery-policy-v3.patch`；新增 3 个 `Diagnostic*Tests.swift`，扩充真实 SDK/Transport/Lifecycle 测试与纯 ObjC fixture；README、configuration/api-and-errors 文档、本验收报告。
- 原先 `RetryConfiguration.swift`、delivery-policy contract、network-and-timeouts、HTTP classification 等交付策略改动保留，未将它们算作本轮诊断策略调整。

产物：

- macOS SDK 静态库：`/tmp/tls-ios-diagnostic-build/out/Products/Debug/libVolcengineTLSProducer.a`
- 真实 ObjC 可运行夹具：`/tmp/tls-ios-diagnostic-objc-fixture`
- 实际生成 macOS ObjC 头：`/tmp/tls-ios-diagnostic-build/out/Intermediates.noindex/GeneratedModuleMaps/VolcengineTLSProducer-Swift.h`
- 实际生成 iOS ObjC 头：`/tmp/tls-ios-diagnostic-device-build/out/Intermediates.noindex/GeneratedModuleMaps-iphoneos/VolcengineTLSProducer-Swift.h`
- iOS device/simulator 编译产物：`/tmp/tls-ios-diagnostic-device-build/out/Products/Debug-iphoneos/`、`/tmp/tls-ios-diagnostic-simulator-build/out/Products/Debug-iphonesimulator/`
- 客户 FILE logger 的真实输出：`/tmp/tls-ios-diagnostic-callback.jsonl`
- 所有验证命令的日志与结果归档：`/tmp/tls-ios-diagnostic-validation/`

## 未完成验收的边界

当前工具链无法构建完整 iOS 13 SDK和 macOS10.15 CocoaPods 最低系统目标；实际移动端 callback/lifecycle 运行需修复本机 Xcode/CoreSimulator/CoreDevice 的版本匹配。以上不标通过。CocoaPods 当前已在 macOS12 / iOS15 的临时验收目标下完成四种编译，并在两个 macOS 外部客户端完成真实文件回调运行，不等同于 iOS 真机运行。


## 2026-10-13 CocoaPods 本机补验

本机 CocoaPods 1.17.0、Ruby 3.3.10、xcodeproj 1.28.1 与 Xcode 27.0 已可用。子 Bash 的 PATH 与交互 zsh 不同，因此通过验证器已有的 `POD_BIN/RUBY_BIN` 参数显式指定工具路径，无需修改系统配置。

第一次按声明的 macOS10.15 / iOS13 目标执行：四种 `pod install` 均成功，Git checkout 清理后私有 modulemap 保留；独立 SwiftPM 纯 Objective-C consumer 已完成公开模块导入、生成头、链接和运行。但 Xcode27 的 deployment target 检查阻止了这四个 CocoaPods 构建。

第二次只在临时验收工程的 xcodebuild 命令设置 `MACOSX_DEPLOYMENT_TARGET=12.0 IPHONEOS_DEPLOYMENT_TARGET=15.0 ARCHS=arm64`，不修改 SDK podspec 或任何业务源。静态库和 static framework 的 macOS/iOS Simulator 四种集成均编译成功。

| 集成模式 | macOS12 | iOS15 Simulator |
| --- | --- | --- |
| CocoaPods 默认静态库 | 生成头/编译/链接及真实运行通过 | 生成头/编译/链接通过，未运行 |
| `use_frameworks! :linkage => :static` | 生成头/编译/链接及真实运行通过 | 生成头/编译/链接通过，未运行 |

两个 macOS CocoaPods 客户端随后分别实际运行 diagnostics off/on：各6业务用例、10请求、6发送回调，case结果完全相同；diagnostics on 各写入106行JSON，最大2122 bytes，7实例，sequence/等级/容量/脱敏验证通过。

复核命令（仓库根）：

```sh
POD_BIN=/opt/homebrew/lib/ruby/gems/3.3.0/bin/pod RUBY_BIN=/opt/homebrew/opt/ruby@3.3/bin/ruby XCODEBUILD_BIN=/tmp/tls-cocoapods-xcodebuild-current-sdk.sh KEEP_SUCCESS=1 POD_SOURCE_MODE=git TLS_OBJC_DIAGNOSTICS=1 TLS_OBJC_DIAGNOSTIC_FILE=/tmp/tls-ios-cocoapods-diagnostic-callback.jsonl bash Producer/scripts/verify-objective-c-producer.sh
```

其中 `/tmp/tls-cocoapods-xcodebuild-current-sdk.sh` 仅执行真实 `/usr/bin/xcodebuild "$@" MACOSX_DEPLOYMENT_TARGET=12.0 IPHONEOS_DEPLOYMENT_TARGET=15.0 ARCHS=arm64`。这不是最低系统版本通过的证据。

完整证据/头文件/可执行客户端/回调输出在 `/tmp/tls-ios-cocoapods-validation/`；临时源码和工程在 `/var/folders/9g/lpj3lyt96mg6720lzgln_2_h0000gn/T/tls-objc-producer.dn6e8F/`。日志中的临时 snapshot commit 是 `5009c70b835078f20ce3edf57d5a7921c83447c4`，不是工作仓库的新提交。

最新环境限制由实际 xcodebuild 日志确认：CoreSimulator 1051.55.0 低于 Xcode 所需1171.7.0；CoreDevice 插件存在符号不匹配。iOS runtime与最低iOS13/macOS10.15验收仍未完成。

## 2026-10-13 最低系统静态核对与发布前待办

- 在 `arm64-apple-ios13.0` 和 `x86_64-apple-macos10.15` 目标下，对 4 个 Bridge Objective-C 源和 3 个 Core C 源执行 availability 检查，共 14 项通过；对全部 17 个 Swift 源执行两个目标的 typecheck，均通过。命令与结果位于 `/tmp/tls-ios-compatibility-static-audit/`。这些检查不包含最低系统上的完整链接、打包或运行。
- 当前已验证的二进制和 CocoaPods 客户端运行在 macOS；iOS 真机/模拟器的网络、生命周期及慢回调运行验收仍待完成。
- 当前 Transport 使用 `NSProcessInfo.systemUptime` 计算耗时，Privacy Manifest 尚需补充相应 SystemBootTime required-reason 声明（elapsed time 用途为 `35F9.1`）。本功能提交保留此发布前待办，不将其标记为已完成。
- 提交前重新核对已验收的 45 个源/测试/配套文件哈希，业务源码未变化；仅补齐未发布 CHANGELOG 和文档状态。Core vendor 重构/补丁/SHA256 校验及现有最终静态库的公开符号检查再次通过。
- 暂存区 whitespace 检查通过：源码和文档使用默认 `git diff --cached --check`；补丁容器单独关闭 `blank-at-eol` 检查。补丁中的 54 个单空格行全部是 unified diff 的空白上下文标记，未修改补丁字节或已登记哈希。

## 2026-10-13 2.0.2 版本同步与内部交付

podspec、固定请求 `User-Agent`、诊断 `sdk_version`、版本校验器与对应测试统一为 2.0.2；未发布 tag 或 Pods 版本。除版本字符串及对应断言/文档外，本轮不调整业务或诊断行为。

- 完整 `swift test --package-path Producer --scratch-path /tmp/tls-ios-diagnostic-build`：379 项，0 failures，4 skipped；日志 `/tmp/tls-ios-v202-swift-tests.log`。
- 实际生成 Objective-C 头、重新链接当前 SDK 并运行：off 环境不设置诊断变量，on 设置 handler。各 6 个用例、10 请求、6 发送回调，业务结果一致；on 的 106 行 JSON 中 `sdk_version` 全为 `2.0.2`，最大 2122 bytes。日志 `/tmp/tls-ios-v202-objc-{off,on}.log`，回调文件 `/tmp/tls-ios-v202-callback.jsonl`，夹具 `/tmp/tls-ios-v202-objc-fixture`。
- `pod ipc spec VolcengineTLSProducer.podspec`：版本 `2.0.2`、source tag `v2.0.2`，最低 iOS13/macOS10.15 声明保留；输出 `/tmp/tls-ios-v202-podspec.json`。这里只解析 manifest，不表示远端 tag 已发布。
- 版本校验器 `bash -n`、修改文件 whitespace 与重新构建 SDK 的公开符号检查通过。新版本结果汇总 `/tmp/tls-ios-v202-test-results.json`；此前 CocoaPods 四种集成的运行记录保留为原版本证据，不冒充本轮重跑。

原始分支与内部 `master`（`b04e65dd19f885004cd1840bf1fc2f831702e13b`）没有共同祖先，Codebase MR 的差异接口报错。内部交付改为从该 master 创建新分支，迁入本工作区的最终文件树；要求新提交的 tree 与本轮已验证的原始实施分支 tree 完全相同，并验证 master 是新分支的祖先。保留原分支和提交，不强推、不改写 master。相对内部 master 还包含现有 2.0.1 module map 修复与 Consumer→Producer 测试/校验工具命名同步。
