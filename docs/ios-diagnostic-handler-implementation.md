**iOS SDK 内部诊断日志回调实现说明**

状态：已在本功能分支实现，尚未发布。本文件保留为实现合同，具体已执行与未完成的验收见[验收记录](ios-diagnostic-handler-validation.md)。目标是在现有结构化 `onDiagnostic` 上增加文本日志适配，让 App 将 SDK 诊断直接写入自己的文件日志系统。

合同核对日期：2026-10-12。原始工作目录：`ve-tls-ios-sdk-modulemap-fix`；原始实施分支：`feat/ios-delivery-policy-alignment`；内部交付分支：`feat/ios-delivery-policy-alignment-internal`；实施前 Git 基线：`8b8a142d3c20a60f0b4a72ed7fd79c991a0b4976`。本方案以当时已有的交付策略工作区为业务基线；交付策略与诊断增量一并纳入功能分支，保留已有改动，不重置为已发布 2.0.1。当前源码标识为待发布的 2.0.2，内部提交基线与文件树一致性核对见验收记录。

**1. 目标与不可变约束**

交付目标是让客户端辨别初始化失败、未入队、入队拒绝、批次等待、请求失败、重试耗尽、数据保留/释放及生命周期影响。新增公开回调需要 SDK 发版；已发布的 2.0.1 不包含 `diagnosticHandler`，不能将下面的接口当作 2.0.1 现有接口。

- **复用现有 `onDiagnostic` 及 Core delivery diagnostic 事件源。** 文本回调是同一事件的格式化适配，不新增一套独立埋点或全局 NSLog 拦截。
- **不改变上传行为。** 不增加或减少请求，不改变载荷、签名、HTTP 头、压缩、批次阈值、发送并发、排序或触发时机。
- **不改变重试行为。** 不调整错误码分类、尝试次数、预算、间隔、唤醒、保留周期或请求超时。
- **不改变持久化行为。** 不改变 WAL 格式、追加、确认、恢复、清理或关闭规则；诊断不能触发业务日志再入队、重发或释放。
- 以主会话当前交付策略草稿为业务基线，诊断启用/关闭的回归对比必须使用完全相同的业务配置。
- App 负责文件路径、轮转和导出。SDK 只负责提供诊断；默认不写文件，也不自动输出 Console。
- 诊断属于有限资源下的尽力投递，不保证进程突然终止前全部回调完成或文件 fsync。

**2. 已有实现与需要补齐的部分**

| 当前文件 | 已有能力 | 本次增量 |
| --- | --- | --- |
| `Producer/Sources/VolcengineTLSProducer/ProducerDiagnostic.swift` | 结构化事件及 Objective-C 包装，含尝试、重试、保留/最终处理、初始化和入队拒绝 | 补公共上下文、等级、统计及网络信息，保持已有字段和 raw value |
| `Producer/Sources/VolcengineTLSProducer/ProducerConfiguration.swift` | `onDiagnostic` 和 open 快照 | 加文本 handler/等级，并纳入快照 |
| `Producer/Sources/VolcengineTLSProducer/Core/RealCoreAdapter.swift` | 连接 Core 诊断与 Swift；当前与发送结果共用 callbackDeliveryQueue | 接入独立、有界的诊断投递器 |
| `Producer/Sources/TLSProducerBridge/Core/TLSRealCoreAdapter.m` | 复制 Core 借用字符串，再 dispatch 到回调队列 | 在无界 dispatch 之前接入有界投递入口，补统计/请求关联 |
| `Producer/Sources/CTLSProducerCore/include/ve_tls_producer.h` | delivery diagnostic、get_metrics、get_buffered_bytes | 复用读取接口，按需追加观察事件/关联信息，不改策略 |
| `Producer/Sources/TLSProducerBridge/Transport/TLSTransport.m` | 请求上下文、SDK 请求截止、底层 NSError 数字码 | 补超时/取消来源、上传进度和可用 Task Metrics |

现有 Core 回调中有 `attempt_count/cycle_attempt_count/log_count/raw_bytes/compressed_bytes/http_code/transport_code/retryable/request_id/error_code`。不要另写代码推导这些已经存在的信息。

**3. 公开回调接口**

Swift 配置新增：

```swift
public enum ProducerDiagnosticLogLevel: Int, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case off = 4
}

public var diagnosticLogLevel: ProducerDiagnosticLogLevel
public var diagnosticHandler:
    (@Sendable (ProducerDiagnosticLogLevel, String) -> Void)?
// 保留已有 onDiagnostic:
// (@Sendable (ProducerDiagnostic) -> Void)?
```

Objective-C Facade 新增同值 `TLSProducerDiagnosticLogLevel` 枚举，以及以下生成头文件合同：

```objc
@property (nonatomic) TLSProducerDiagnosticLogLevel diagnosticLogLevel;
@property (nonatomic, copy, nullable)
    void (^diagnosticHandler)(NSInteger level, NSString *message);
// 保留现有 onDiagnostic(TLSProducerDiagnostic *)。
```

Objective-C block 的 level 使用 NSInteger，保证客户截图中的写法能直接编译；Facade 将 Swift 等级转换为 rawValue。以下是未来新版本的接入示例：

```objc
config.diagnosticLogLevel = TLSProducerDiagnosticLogLevelInfo;
config.diagnosticHandler = ^(NSInteger level, NSString *message) {
    BXLogI(@"[VolcTLS-SDK][terminal] %@", message);
};
```

接口规则：

1. handler 默认为 nil，文本等级默认 Info。两个 handler 都为 nil，或仅文本 handler 存在且等级 Off 时，使用禁用/no-op 路径。
2. `diagnosticLogLevel` **只过滤文本回调**；已有结构化 `onDiagnostic` 不受文本等级影响。两者同时配置时，同一已投递事件分别回调一次。
3. 文本 threshold 规则：Debug 接收 0..3；Info 接收 1..3；Warning 接收 2..3；Error 仅接收 3；Off 不产生文本。Off 不作为回调事件等级。
4. handler 与等级在 open 边界复制到不可变快照。open 后修改原 config 不热更新，也不能由修改 block 影响其他 Producer。
5. 客户回调在 SDK 自有串行诊断队列执行，默认不在主线程，不使用 onSendResult 的队列。两种诊断回调在同一事件上先结构化、后文本。
   这是对当前未发布草稿的诊断线程合同调整，需同步公开文档和测试；原 onSendResult/completion 的回调线程合同保持不变。若客户把两个诊断 handler 接到同一文件，可能主动记录两份同一事件，SDK 不替其去重。
6. 客户可在回调中调用现有文件 logger；不要同步等待 SDK 的 add/close，也不要把诊断重新送入同一 Producer。

**4. 统一事件源与投递器**

新增内部 `DiagnosticEmitter.swift` 与 `DiagnosticFormatter.swift`。所有 Core、Transport、Producer、Facade 和 Lifecycle 事件进入同一个 emitter；原 `onDiagnostic` 与新文本 handler 由 emitter 统一投递。

- emitter 必须在 Objective-C swiftValue 转换、Swift open 校验、目录准备及 Core 创建之前建立，保证初始化失败也有实例 ID 和回调入口。配置对象本身尚未构造成功的 Swift initializer 错误，仍由调用者捕获。
- 给 Core/Bridge/Transport 的内部 sink 只复制白名单字段并调用非业务阻塞的 offer；它不是客户回调。
- **不能先沿现有路径 dispatch_async 大量 block，再在下游做队列上限。** 需要在第一次异步排队前就控制容量。
- 每实例 FIFO 事件队列上限 1024。队列满立即计数并丢弃诊断，不阻塞上传；恢复后由 drain 输出 `diagnostics_dropped` 汇总，汇总本身不要递归经过满队列。
- 时间在事件发生时捕获；sequence 在有界队列准入时分配，表示该实例的诊断入队顺序。耗时使用诊断自己的单调时钟；不要顺便改变现有重试时钟。
- 客户代码和 JSON 格式化都不在 Core/SDK 锁或 URLSession delegate 热路径执行。复制 C 字符串后才能跨线程，不能保留借用指针。
- handler=nil 时不要建立 timer、格式化文本或采集详细 metrics。启用结构化 handler 时仍保留已有结构化事件内容。
- slow handler 会延迟后续诊断，但不得延迟 onSendResult、初始化完成、关闭完成或原生发送工作。close 不等待客户文件 I/O。
- Core 关闭后禁止采集新 Core 数据；已经准入的诊断可继续排出。timer 停止与 native 指针保护必须遵循 Adapter 的生命周期规则，避免 close/get_metrics 并发 use-after-free。

**5. 诊断消息格式与字段**

message 使用单行 JSON，schema_version 固定为 1。统一 formatter 输出，字符串转义通过 JSONSerialization 完成，不手工拼接。下面是示意消息，不是现有 SDK 的真实输出：

```json
{"schema_version":1,"event":"attempt_finished","level":2,"source":"core","time_ms":1791734400000,"sequence":12,"sdk_version":"<release-version>","producer_instance_id":"<uuid>","producer_id":"tls-terminal","topic_id":"<topic-id>","batch_start_id":100,"batch_end_id":120,"attempt_count":3,"cycle_attempt_count":3,"http_code":0,"transport_code":2103,"timeout_source":"sdk_request_deadline","request_id":null}
```

字段缺失使用省略或 null，整个 schema 统一选择 null 作为已定义但不可取得的值。不要用 0 代替未知耗时、未知上传字节或未知状态。http_code=0 是特例，明确表示没有可用 HTTP 响应，不是服务端 HTTP 0。

| 字段 | 类型/单位 | 语义与来源 |
| --- | --- | --- |
| schema_version | Int=1 | 格式版本 |
| event / level / source | String / Int / String | 稳定事件名、等级、facade/producer/core/transport/lifecycle |
| time_ms / sequence | Int64 / Int64 | 事件发生的 Unix 毫秒、实例内诊断准入顺序 |
| sdk_version / producer_instance_id | String | 版本统一读取 SDK 版本来源；实例 ID 在 open 前生成 |
| producer_id / topic_id / endpoint_host | String? | 逻辑 ID/Topic/规范化主机；缺失或不安全输入置 null，不改变原业务校验 |
| batch_start_id / batch_end_id / log_count | Int64? / Int64? / Int? | Core 实际批次范围和条数；非批次事件置 null，不能把默认 0 当真实批次 |
| attempt_count / cycle_attempt_count | Int? | 保留现有累计尝试与当前周期尝试语义，不将其重新计算为请求数 |
| raw_bytes / compressed_bytes | Int?，bytes | 现有 Core 口径；不可把请求字节数当唯一业务丢失量 |
| delivery_elapsed_ms / retry_delay_ms | Int?，ms | 现有 elapsed/retryDelay 转为毫秒，保留原语义 |
| attempt_elapsed_ms / queue_wait_ms | Int?，ms | 本次尝试起止、封包后到开始发送；仅有实际时间点时输出 |
| http_code / request_id / error_code | Int / String? / String? | HTTP 状态、规范化且可关联服务端的完整 RequestID、原事件错误名 |
| producer_error_domain / producer_error_code / producer_error_name | String? / Int? / String? | Facade/Producer 实际错误，不能与 HTTP 状态或 Transport 数字码混用 |
| transport_kind / transport_error_domain / transport_code | String? / String? / Int? | Transport 分类、对应命名空间和实际错误码；保持既有 transportCode 值 |
| underlying_error_domain / underlying_error_code | String? / Int? | 可确认的底层 NSError domain/code，仅复制这两个白名单字段 |
| retryable / reason / disposition | Bool? / String? / String? | 可重试分类、停止/保留原因、实际 success/discard/retained_memory/retained_wal/unknown |
| timeout_source / cancel_source | String? | SDK deadline、URLSession timeout；显式取消、close、invalidate 或 unknown，按真实分支标记 |
| app_state / automatic_lifecycle_handling | String? / Bool? | foreground/background/unknown 与生命周期开关；不推测系统强杀 |
| buffer_used_bytes / buffer_limit_bytes | Int?，bytes | get_buffered_bytes 的总预算口径，含队列/在途/临时/TLS 数据，不等于纯业务 payload |

初始化配置摘要另带 batch_count、batch_raw_bytes、linger_ms、send_concurrency、compression、persistence_mode、请求/idle 超时、重试次数/预算/间隔、memory retention 和 lifecycle 开关；只输出**当前实际配置**，不重设任何配置值。带时间的字段一律注明 ms，不把公开 TimeInterval 的秒值直接写入 _ms 字段。

周期统计（60 秒；只在诊断启用且进程获运行时间时执行）：

| 字段组 | 定义 |
| --- | --- |
| add_attempted_total / add_accepted_total / add_rejected_by_error | Facade/Producer 调用边界累计值，覆盖校验失败和未 ready；成功只表示入队边界成功 |
| core_logs_enqueued_total / core_logs_dropped_total / core_batches_built_total | 复用 Core get_metrics，对外声明为 Core 口径，不与 Facade 拒绝重复求和 |
| core_requests_total / core_requests_failed_total / core_retries_total / core_bytes_sent_total | Core 原始统计口径；bytes_sent_total 不改名为服务端写入字节 |
| buffer_used_bytes / buffer_limit_bytes | 复用 Core 缓冲读取；native 不可读取时置 null |
| diagnostic_dropped_total / diagnostic_dropped_since_last_report | emitter 自身丢弃数量，与业务日志丢弃分开 |

Core metrics 是分别读取的计数，缓冲读取在另一时刻完成，不能宣称它们是一份严格原子快照。入队失败在持久化模式下可能已写入 WAL，不能根据 NSError 或 add 返回失败就记录 disposition=discard。确切处置必须在实际确认、保留或释放分支采集。

`get_buffered_bytes` 自行获取 producer mutex，不能在不清楚 Core 持锁状态的 C 诊断回调内直接调用。周期采集在 Bridge 已保护 native 生命周期、且不处于 Core 锁内的入口读取；事件中不能安全取得的水位先置 null，不能为补字段嵌套加锁或等待网络工作线程。

**6. 事件覆盖与等级**

| event | 来源 | 文本等级 | 必须覆盖的边界 |
| --- | --- | --- | --- |
| open_started | Facade/Producer | Info | 校验之前，仅创建诊断上下文；无凭证内容 |
| opened / open_failed | Producer、Facade 转换失败 | Info / Error | 成功和每条失败出口各一次，包括配置、凭证、目录、Core 构建；避免双重 catch 重复发同一失败 |
| admission_rejected | Facade/Producer | Warning | 不支持的 ObjC mode、状态检查、日志校验、大小检查和 Core add 失败；记录 admission_stage |
| admission_summary | Producer/Adapter | Info | 每 60 秒及受控关闭前的调用/拒绝、Core 计数、缓冲使用量 |
| batch_sealed | Core manager | Debug | 实际批次已构建，记录条数/范围/大小，不额外封包或 flush |
| attempt_started / attempt_finished | Core sender | Debug / 成功 Debug、失败 Warning | 每个实际尝试的开始与完成，不因日志级别改变尝试动作 |
| retry_scheduled | Core sender | Debug | 实际重试安排，输出实际 delay 与原因 |
| batch_retained | Core sender/persistence | Warning | 实际内存/WAL 保留或延迟重试，不能报成最终丢弃 |
| batch_terminal | Core sender/persistence | 成功 Info、失败 Error | 实际最终处置；不要将所有失败一概视为已释放 |
| transport_finished / transport_metrics | Transport | 失败 Warning；成功/补充指标 Debug | 请求实际完成和可用指标，关联同一个 attempt_id |
| lifecycle | Lifecycle manager | Info；执行时间到期 Warning | 现有 background/foreground/expiration 分支；不新增取消、close 或额外后台任务 |
| close_started / closed / close_failed | Producer/Adapter | Info / Info / Warning | timeout/成功及待发送量；不延长 close 原期限 |
| diagnostics_dropped | Emitter | Warning | 队列恢复后的诊断丢弃汇总 |

不得用诊断去执行 retry、notifyNetworkRecovered、flush、close 或修改凭证。只在原操作已发生的分支上观察。automaticLifecycleHandling 关闭或 extension 中不可获取 App 状态时，输出 disabled/unknown，不为采集诊断新增 UIApplication 调用。

raw value 合同：现有 Swift Kind 保持 unknown=-1、attemptFinished=0、retryScheduled=1、batchRetained=2、batchTerminal=3、admissionRejected=4、opened=5、closed=6、openFailed=7；现有 Reason 值也不重排。新增 Swift/ObjC Kind 在末尾追加并显式赋值，事件 JSON 使用稳定名称。

**Core 现有事件只占 0..3，不能把新增 Core 的 4 按 rawValue 直接转成 Swift Kind，否则会误报 admissionRejected。** 新增 Core 事件使用独立明确值表；在 Bridge/RealCoreAdapter 进行显式映射并逐项测试，unknown 保留 unknown。不改变已有 kind/reason/elapsed/retryDelay 等公开字段的含义。

**7. Transport 关联与指标**

现有请求上下文的本地 UUID 与服务端 RequestID 是不同标识。引入内部 attempt_id，贯穿 Core 实际尝试、Bridge 请求构造、TLSHTTPRequest、Transport context 和诊断事件，并保留 batch range 与 attempt counters。该关联信息不得进入 HTTP 头、查询参数、签名或业务 payload。

如果需要在 C HTTP request 增加上下文，使用带版本/大小约定的内部扩展，复制后再异步使用，不传裸 task 指针。维护一份显式关联映射，不按时间相近猜测哪个请求属于哪个批次。

在现有 URLSession delegate proxy 上转发 didSendBodyData 与 didFinishCollectingMetrics：

- 上传进度只更新请求上下文，不逐个进度回调刷日志；完成/失败时输出 sent_body_bytes 和 expected_body_bytes。未取得指标时为 null，平台返回 unknown 时保持未知。
- metrics 立即提取标量，不把 NSURLRequest、原始 metrics 对象、NSError 或含凭证的对象排入诊断队列。
- 可用字段：dns_ms、connection_setup_ms、tls_handshake_ms、request_send_ms、response_wait_ms、response_read_ms、network_protocol、connection_reused。每个 duration 仅在起止均存在且合理时计算，否则 null。
- connection_setup_ms 与 tls_handshake_ms 可能存在包含关系，不相加为总耗时。复用连接可能没有 DNS/握手时间，不能推断为阶段未执行或阶段超时。
- SDK request deadline 分支记录 timeout_source=sdk_request_deadline；NSURLErrorTimedOut 记录 urlsession_timeout，不声称一定是 idle/DNS/握手超时。Core retry budget 记录 reason=retry_budget，不伪装为网络超时。
- 取消来源只能从实际取消分支得出。NSURLErrorCancelled 无明确来源时写 unknown，不统一归因于后台。
- HTTP 408 仍为 HTTP 结果；本地 timeout 的 http_code 可为 0。只读诊断不得改动当前错误分类和 retryable。
- SDK 提前完成/取消可能先移除 context，metrics 随后到达：使用有界、短生命周期的诊断关联记录（建议最多 128 个、TTL 30 秒），允许补充事件缺失。不要等待 metrics 或让它阻塞请求完成、重试与 close。

Apple 参考：[上传进度/字节口径](https://developer.apple.com/documentation/foundation/urlsessiontask/countofbytessent)、[任务指标回调](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession%28_%3Atask%3Adidfinishcollecting%3A%29?language=objc)、[DNS 时间可能缺失](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/domainlookupenddate)。

**8. 字段白名单与资源限制**

只允许上述固定字段及固定配置摘要。不得记录 AK/SK、SessionToken、Authorization、原始请求头/响应体、日志 contents/hashKey/tags、完整 URL、任意 NSError.userInfo 或 Core error_message。请求主机从规范化 URL 提取，过滤 userinfo/path/query/fragment；复用现有脱敏工具。错误文本使用固定脱敏摘要，不复制服务端自由文本。

RequestID 使用已规范化的完整值，方便服务端关联；不要用指纹替代。输入超出约定或非法时省略并标记，不静默截取成另一个看似合法的 ID。

文本消息上限 4 KiB UTF-8。入队前限制可复制字符串长度和 metrics 数量，避免 1024 个事件仍携带无界对象。超长消息优先省略可选详情，并设置 fields_omitted；仍过长则计入丢弃。不能直接截断 JSON 或 UTF-8，破坏可解析性。App 需要更大日志策略时由 App 自己处理文件，不扩大 SDK 默认队列。

**9. 修改文件清单**

以下路径相对当前 SDK 仓库根。新增文件为规划项，其余为已有文件；按最小增量修改，不覆盖主会话已有策略改动。

| 文件 | 修改责任 |
| --- | --- |
| `Producer/Sources/VolcengineTLSProducer/ProducerConfiguration.swift` | 新增 Swift handler/等级、默认值、校验与 ConfigurationSnapshot |
| `Producer/Sources/VolcengineTLSProducer/ObjectiveC/TLSProducerFacade.swift` | ObjC enum/NSInteger block、配置转换和初始化前 emitter；捕获 Facade 层入队拒绝 |
| `Producer/Sources/VolcengineTLSProducer/ProducerDiagnostic.swift` | 扩展 typed 诊断字段、追加事件，维护 ObjC DTO 同步 |
| `Producer/Sources/VolcengineTLSProducer/Diagnostics/DiagnosticEmitter.swift`（新增） | 实例上下文、有界队列、统一双回调、sequence/drop 计数、等级过滤 |
| `Producer/Sources/VolcengineTLSProducer/Diagnostics/DiagnosticFormatter.swift`（新增） | 白名单单行 JSON、字段/单位/容量规范 |
| `Producer/Sources/VolcengineTLSProducer/Producer.swift` | open/add/close 的观察事件与 Facade/Producer 计数，避免重复 catch |
| `Producer/Sources/VolcengineTLSProducer/Core/CoreAdapter.swift` | 诊断 sink/统计读取内部合同和测试 Adapter 默认行为；不改业务 add/open/close 语义 |
| `Producer/Sources/VolcengineTLSProducer/Core/RealCoreAdapter.swift` | 接入 emitter、独立诊断队列、显式 Kind 映射、60 秒汇总、生命周期释放 |
| `Producer/Sources/TLSProducerBridge/Core/TLSRealCoreAdapter.h` | 内部诊断 sink、受保护统计读取和请求关联声明 |
| `Producer/Sources/TLSProducerBridge/Core/TLSRealCoreAdapter.m` | Core 字段安全复制、有界排队前的 sink、metrics/buffer getter、关闭并发保护 |
| `Producer/Sources/TLSProducerBridge/Transport/TLSHTTPRequest.h` / `.m` | 添加只供诊断的关联上下文；不改变网络请求构造 |
| `Producer/Sources/TLSProducerBridge/Transport/TLSHTTPResponse.h` / `.m` | 仅在携带安全诊断快照确有需要时扩展；不改响应/错误分类 |
| `Producer/Sources/TLSProducerBridge/Transport/TLSTransport.h` / `.m` | 内部诊断 sink、context、delegate proxy、时间/字节/取消来源与 late metrics |
| `Producer/Sources/TLSProducerBridge/Lifecycle/TLSLifecycleManager.h` / `.m` | 现有生命周期分支的观察 hook，保留 extension 与后台任务配对合同 |
| `Producer/Sources/CTLSProducerCore/include/ve_tls_producer.h` | 按需追加 Core 诊断事件/扩展，原值不变 |
| `Producer/Sources/CTLSProducerCore/core/src/producer/ve_tls_producer_internal.h` | 只存必要诊断关联/时间点，不改调度条件 |
| `Producer/Sources/CTLSProducerCore/core/src/producer/ve_tls_producer_sender.c` | 实际 attempt_started 与现有完成/重试/处置事件复用 |
| `Producer/Sources/CTLSProducerCore/core/src/producer/ve_tls_producer_manager.c` | 实际 batch_sealed 的观察事件，如新增字段需从真实批次获取 |
| `Producer/Tests/ContractTests/DiagnosticConfigurationTests.swift`（新增） | 默认/快照/等级/ObjC 接口测试 |
| `Producer/Tests/ContractTests/DiagnosticEmitterTests.swift`（新增） | 双回调、队列隔离/上限、sequence、关闭生命周期与 no-op 路径 |
| `Producer/Tests/ContractTests/DiagnosticFormatterTests.swift`（新增） | JSON/单位/缺失值/脱敏/容量/枚举映射 |
| `Producer/Tests/ProducerIntegrationTests/RealCoreAdapterIntegrationTests.swift` | 真实 Core admission/尝试/重试/处置与 on/off 行为对比 |
| `Producer/Tests/TransportTests/TLSTransportTests.swift` | 超时/取消/上传进度/metrics/迟到事件的受控测试 |
| `Producer/Tests/PersistenceTests/LifecycleManagerTests.swift` | lifecycle hook、extension 与后台任务配对保持原样 |
| `Producer/Tests/ObjectiveCProducer/main.m` | 用客户 NSInteger/NSString block 写法验证生成头文件及运行接入 |
| `docs/reference/configuration.md` / `docs/reference/api-and-errors.md` / `Producer/README.md` | 新接口、等级、线程、best-effort 和上传/重试/持久化不变说明 |

Core 变化须同步主 C 仓库或现有 core-patches 机制，再更新 `Producer/CORE_VERSION`、`Producer/CORE_VENDOR_SHA256SUMS`，通过 `Producer/scripts/verify-core-vendor.sh`。只修改必要清单/补丁，不绕过校验，也不将诊断变成长期未同步的 iOS fork。

**10. 实施顺序**

1. 先固定业务基线：记录当前版本/策略配置及既有回归结果，建立同配置 diagnostics off/on 的对照。不要先改错误码、重试或持久化以让诊断用例通过。
2. 定义公开 API、事件名称/映射与 schema；先补 configuration/formatter/ObjC 编译合同测试。
3. 建立 emitter 并接入已有 onDiagnostic，验证默认关闭、双回调、慢 handler、队列上限与初始化失败；再补文本 adapter。
4. 添加 Facade/Producer 的入队统计和 Core 统计读取，验证拒绝/缓存口径与 close 并发安全。
5. 接入 Core batch/attempt 观察及 Transport 关联、指标、生命周期 hook，不改任何实际业务决策。
6. 完成下列验收，更新公开文档和 Objective-C 示例；报告最终 commit、生成头文件、验证产物和未覆盖的真机边界。

**11. 验收用例**

| ID | 场景/构造 | 必须观察到的结果 |
| --- | --- | --- |
| D01 | 无两个 handler；仅文本 Off | 无客户回调、无文本格式化/汇总 timer/详细采集，业务结果与基线一致 |
| D02 | ObjC 按截图用 NSInteger block；iOS 13 target | 真实生成头文件可编译；等级数值、nullability、copy 属性符合合同 |
| D03 | 仅结构化/仅文本/两者同时/文本 Off + 结构化 | 结构化保留既有字段；双回调同 sequence 各一次；文本 Off 不关掉结构化 |
| D04 | Info/Warning/Error/Debug 分别启用 | threshold 正确；过滤文本不改变请求、重试或结构化事件 |
| D05 | open 后替换 config block/等级；event/terminal 两个实例 | 原实例使用快照，不热更新、不串实例或 Topic |
| D06 | 无 destination、非法配置、凭证校验失败、目录/Core 构建失败 | 初始化前有 instance_id；open_failed 每失败路径一次，原 NSError/throws/completion 保持 |
| D07 | ObjC mode 无法映射、未 ready、invalidLog、singleLogTooLarge、queueFull/bufferFull/closed | admission_rejected 带正确阶段/错误，计数准确；不把拒绝或 WAL 已追加直接判为 discard |
| D08 | 多线程 add，成功与拒绝混合；周期/受控关闭汇总 | 调用累计和分类计数正确，未知统计 null，Core/Facade 计数不重复求和 |
| D09 | 普通批次和未达到触发阈值的批次 | batch_sealed/attempt_started 只在原动作发生时出现，诊断不触发 flush |
| D10 | 受控 HTTP 2xx、400、408、429、5xx 与本地 timeout/network lost | HTTP 与 transport 命名空间分开；on/off 错误分类、实际请求次数/次序、backoff/预算一致 |
| D11 | 最大尝试、预算、保留期耗尽；内存保留关闭/开启，WAL 保留 | reason/disposition 与实际分支一致；释放和保留数量及 onSendResult 次数与基线一致 |
| D12 | 对同一业务批次录制 on/off 请求 | payload、签名输入、压缩、头、URL 和写入内容无诊断字段；若签名含实时值则固定时钟或比较签名输入，不能盲比不同时间的签名 |
| D13 | 人为阻塞客户 diagnosticHandler，制造 >1024 个事件 | 准入有上限、不等待客户代码，drop 汇总真实；add、请求完成、onSendResult 和 close 仍推进，无无界 dispatch backlog |
| D14 | 多线程事件、墙钟变化、JSON 字符/长字段 | sequence 唯一按准入排序，time_ms 为发生时间，诊断耗时非负，文本单行可解析且 <=4KiB |
| D15 | Core 新事件值与 Swift 4/5/6/7 重叠 | 显式映射正确，尤其新增 Core 4 不误报 admissionRejected，未知值不误归类 |
| D16 | 注入凭证、正文、带 userinfo/query URL、服务端错误文本 | 所有文本/结构化回调及 DTO description 都无敏感原文；合法 RequestID 能完整关联 |
| D17 | SDK deadline、NSURLErrorTimedOut、显式 cancel、invalidate、来源不明的 -999 | 正确 timeout_source/cancel_source；一次原有请求终态，不改变 retryable |
| D18 | 部分上传、无进度回调、连接复用、缺失/迟到 metrics | 已观察字节/时间正确；未知 null；迟到事件关联 attempt_id；不等待 metrics、不新增请求 |
| D19 | foreground/background/expiration、automaticLifecycleHandling=NO、App Extension | 仅观察已有分支；原 flush/wake/后台任务配对不变，不新增 UIKit/取消行为 |
| D20 | close 成功/超时与统计采集、迟到回调并发 | 无 native use-after-free、无 handler 引用循环；close 不等客户文件 I/O，已准入事件有清晰生命周期 |
| D21 | 非持久化、buffered/sync WAL 失败/恢复/确认/删除 | diagnostics on/off 存盘、恢复、ACK/清理与内存释放相同，无新增 WAL 字段；复用当前持久化回归夹具 |

HTTP、计时、重试和 WAL 行为对比优先使用受控 transport/fake clock 或现有夹具，不能根据公网波动判断策略改变。先跑相关定向测试；发生新变化或失败再扩展检查，不重复跑无关大范围测试。

供主会话实施后运行（从仓库根，新增测试实际落地后）：

```sh
swift test --filter Diagnostic
swift test --filter RetryConfigurationTests
swift test --filter RealCoreAdapterIntegrationTests
swift test --filter TLSTransportTests
swift test --filter LifecycleManagerTests
bash Producer/scripts/verify-core-vendor.sh
```

Objective-C 使用现有 `Producer/scripts/verify-objective-c-producer.sh`，先检查该脚本的当前 help/参数和环境，再按支持的构建入口运行，不猜测 flags。实际生成的公共头文件要保留，至少完成 iOS 13 编译和真实 SDK 的回调冒烟；前后台/强杀/文件保护需单独列出真机验证范围。

**12. 完成判定与交接输出**

主会话只有在新增接口/文档完成、关键验收通过、业务行为 on/off 对比通过及 Core vendor 检查通过后才能标记完成。需交付：修改文件/commit、生成头文件位置、定向测试输出、Objective-C 接入示例、行为对照结果、真机检查结果或尚未验证的边界。

SDK 日志足以显示哪个 SDK 边界异常，但不能证明 SDK 从未被业务调用，也不能可靠捕获进程被强杀的最后一刻；App 仍应保留启动、业务调用和自己的文件导出信息。message 回调完成也不等于 App 文件已持久化。

原始合同交接时只新增本 Markdown，尚未实现 SDK 接口或执行验收；后续实现与验证结果以本功能分支及验收记录为准。
