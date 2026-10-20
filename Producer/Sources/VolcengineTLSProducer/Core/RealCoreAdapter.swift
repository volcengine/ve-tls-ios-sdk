//
//  RealCoreAdapter.swift
//  VolcengineTLSProducer/Core
//
//  Swift wrapper around the Objective-C bridge to ve-tls-c-sdk v0.3.1.
//

import Foundation

#if SWIFT_PACKAGE
import TLSProducerBridge
#else
@_implementationOnly import TLSProducerBridge
#endif

/// CoreAdapter backed by the vendored C Core.
///
/// The Objective-C bridge owns the Core/HTTP lifetimes. This layer owns the
/// public error mapping, sandbox directory preparation, lifecycle helper, and
/// Swift callback contract.
internal final class RealCoreAdapter: CoreAdapter, @unchecked Sendable {

    private enum CoreResult: Int {
        case ok = 0
        case invalid = 1
        case dropped = 2
        case persistence = 3
        case closed = 4
        case timeout = 5
    }

    private enum Operation {
        case open
        case add
        case updateCredentials
        case updateDestination
        case close
    }

    private let stateLock = NSLock()
    private var _onSendResult: (@Sendable (SendResult) -> Void)?
    private var opened = false
    private var closed = false
    private var lifecycleManager: TLSLifecycleManager?

    private let adapter: TLSRealCoreAdapter
    private let automaticLifecycleHandling: Bool
    private let diagnosticEmitter: DiagnosticEmitter
    private let bufferLimitBytes: Int64
    private var diagnosticTimer: DispatchSourceTimer?
    private var diagnosticSamplingStopped = false
    private var diagnosticAppState = "unknown"
    internal static var sdkVersion: String { TLSRealCoreAdapter.sdkVersion }
    private let callbackDeliveryQueue: DispatchQueue

    var onSendResult: (@Sendable (SendResult) -> Void)? {
        get { withStateLock { _onSendResult } }
        set { withStateLock { _onSendResult = newValue } }
    }

    init(configuration: ProducerConfiguration, credentials: Credentials) throws {
        guard let destination = configuration.destination else {
            throw ProducerError.configuration("destination is required")
        }
        try destination.validate()
        try credentials.validate()

        let persistentDirectory = try Self.preparePersistentDirectory(
            configuration: configuration)
        let persistenceMode: TLSRealCoreAdapterPersistenceMode
        switch configuration.persistence {
        case .disabled, .memory:
            persistenceMode = .disabled
        case .buffered:
            persistenceMode = .buffered
        case .sync:
            persistenceMode = .sync
        }

        // Preserve the serial callback guarantee even if the caller supplies
        // a concurrent queue: this private serial queue targets their queue.
        callbackDeliveryQueue = DispatchQueue(
            label: "com.volcengine.tls.producer.callback.delivery",
            qos: .utility,
            target: configuration.callbackQueue)
        diagnosticEmitter = configuration.diagnosticEmitter ?? Producer.makeDiagnosticEmitter(configuration)
        bufferLimitBytes = Int64(configuration.buffer.maxBytes)
        let emitter = diagnosticEmitter
        let sink: TLSRealCoreAdapterDiagnosticHandler?
        if emitter.isEnabled {
            sink = { fields in emitter.offer(RealCoreAdapter.diagnostic(from: fields)) }
        } else { sink = nil }
        automaticLifecycleHandling = configuration.automaticLifecycleHandling

        do {
            adapter = try TLSRealCoreAdapter(
                endpoint: destination.endpoint,
                region: destination.region,
                projectID: destination.projectID,
                topicID: destination.topicID,
                accessKeyID: credentials.accessKeyID,
                accessKeySecret: credentials.accessKeySecret,
                securityToken: credentials.securityToken,
                source: configuration.metadata.source,
                fileName: configuration.metadata.fileName,
                tags: configuration.metadata.tags.isEmpty ? nil : configuration.metadata.tags,
                maxLogCount: configuration.batch.maxLogCount,
                maxRawBytes: configuration.batch.maxRawBytes,
                linger: configuration.batch.linger,
                maxBufferBytes: configuration.buffer.maxBytes,
                connectTimeout: configuration.connectTimeout,
                requestTimeout: configuration.requestTimeout,
                requestIdleTimeout: configuration.requestIdleTimeout,
                retryMaxAttempts: configuration.retry.maxAttempts,
                retryTotalTimeout: configuration.retry.totalTimeout,
                retryInitialInterval: configuration.retry.initialInterval,
                retryMaxInterval: configuration.retry.maxInterval,
                memoryRetryRetention: configuration.memoryRetryRetention,
                retryTransientHTTPResponses: configuration.retry.retryTransientHTTPResponses,
                lz4Enabled: configuration.compression == .lz4,
                sessionConfiguration: configuration.urlSessionConfiguration,
                bufferFullPolicy: configuration.buffer.fullPolicy == .block ? 1 : 0,
                sendConcurrency: configuration.sendConcurrency,
                bufferFullBlockTimeout: configuration.buffer.fullPolicy == .block
                    ? configuration.buffer.blockTimeout
                    : 0,
                persistenceMode: persistenceMode,
                persistentDirectory: persistentDirectory,
                maxLogAgeSeconds: Int(configuration.maxLogAge),
                expiredLogPolicy: configuration.expiredLogPolicy == .drop ? 1 : 0,
                authFailurePolicy: configuration.unauthorizedPolicy == .drop ? 1 : 0,
                diagnosticSink: sink,
                callbackQueue: callbackDeliveryQueue)
        } catch {
            throw Self.mapBridgeError(error, operation: .open)
        }

        adapter.onSendResult = { [weak self] result,
            rawBytes,
            compressedBytes,
            httpCode,
            errorCode,
            errorMessage,
            requestID,
            transportKind,
            transportCode,
            retryable,
            _, _ in
            guard let self else { return }
            let producerError = Self.mapSendFailure(
                result: result,
                httpCode: httpCode,
                errorCode: errorCode,
                errorMessage: errorMessage,
                requestID: requestID,
                transportKind: transportKind,
                transportCode: transportCode,
                retryable: retryable)
            let sendResult = SendResult(
                status: result == CoreResult.ok.rawValue ? .success : .failure,
                rawBytes: Int(rawBytes),
                compressedBytes: Int(compressedBytes),
                requestID: requestID,
                error: producerError)
            self.onSendResult?(sendResult)
        }
    }

    deinit {
        stopDiagnosticSampling()
        transferLifecycleManagerReleaseToMainThread()
    }

    func open(configuration: ProducerConfiguration, credentials: Credentials) throws {
        let canOpen = withStateLock { !opened && !closed }
        guard canOpen else {
            throw withStateLock { closed }
                ? ProducerError.closed
                : ProducerError.invalidState
        }

        do {
            try adapter.open()
        } catch {
            throw Self.mapBridgeError(error, operation: .open)
        }
        withStateLock { opened = true }
        installLifecycleManagerIfNeeded()
        startDiagnosticSampling()
    }

    func add(_ event: PreparedLogEvent, mode: AddMode) throws {
        try ensureOpen()
        do {
            // Swift Data bridges to an autoreleased NSData at the ObjC call.
            // A caller may perform a long synchronous add loop without ever
            // draining its own pool, so bound those bridge temporaries here.
            try autoreleasepool {
                try event.encodedLengths.withUnsafeBufferPointer { lengths in
                    try adapter.addLog(
                        withTimestamp: event.timestampMilliseconds,
                        nanosecondRemainder: event.timestampNanosecondsRemainder,
                        hashKey: event.hashKey,
                        fieldBytes: event.encodedFieldBytes,
                        lengths: lengths.baseAddress,
                        lengthCount: UInt(lengths.count),
                        flush: mode == .immediate)
                }
            }
        } catch {
            throw Self.mapBridgeError(error, operation: .add)
        }
    }

    /// Internal test convenience for exercising this adapter without the
    /// `Producer` facade. Public admission always passes a prepared snapshot.
    func add(_ event: LogEvent, mode: AddMode) throws {
        try add(event.prepareForAdmission(), mode: mode)
    }

    func updateCredentials(_ credentials: Credentials) throws {
        try ensureOpen()
        try credentials.validate()
        do {
            try adapter.updateCredentials(
                credentials.accessKeyID,
                accessKeySecret: credentials.accessKeySecret,
                securityToken: credentials.securityToken)
        } catch {
            throw Self.mapBridgeError(error, operation: .updateCredentials)
        }
    }

    func updateDestination(_ destination: Destination) throws {
        try ensureOpen()
        try destination.validate()
        do {
            try adapter.updateDestination(
                destination.endpoint,
                region: destination.region,
                projectID: destination.projectID,
                topicID: destination.topicID)
        } catch {
            throw Self.mapBridgeError(error, operation: .updateDestination)
        }
    }

    func close(timeout: TimeInterval) async throws {
        if withStateLock({ closed }) { return }

        stopDiagnosticSampling()
        removeLifecycleManager()
        do {
            // The C Core close joins worker threads and may consume the full
            // caller-provided timeout. Keep that bounded synchronous work off
            // the caller's executor (especially MainActor).
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    do {
                        try adapter.close(withTimeout: timeout)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            withStateLock { closed = true }
        } catch {
            throw Self.mapBridgeError(error, operation: .close)
        }
    }

    private func ensureOpen() throws {
        let state = withStateLock { (opened, closed) }
        if state.1 { throw ProducerError.closed }
        if !state.0 { throw ProducerError.invalidState }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // MARK: - Persistence

    private static func preparePersistentDirectory(
        configuration: ProducerConfiguration
    ) throws -> String? {
        switch configuration.persistence {
        case .disabled, .memory:
            return nil
        case .buffered, .sync:
            guard let producerID = configuration.producerID else {
                throw ProducerError.configuration(
                    "producerID is required when persistence is .buffered or .sync")
            }
            do {
                let directory = try TLSProducerDirectory.defaultDirectoryURL(
                    forProducerID: producerID)
                guard TLSProducerDirectory.isURL(
                    directory,
                    insideContainerBaseURL: nil) else {
                    throw ProducerError.persistence(
                        "producer directory is outside the application container")
                }
                return try TLSProducerDirectory.createDirectory(at: directory).path
            } catch let error as ProducerError {
                throw error
            } catch {
                throw ProducerError.persistence("producer directory preparation failed")
            }
        }
    }

    func notifyNetworkRecovered() { adapter.notifyNetworkRecovered() }

    func emitDiagnostic(_ diagnostic: ProducerDiagnostic) {
        diagnosticEmitter.offer(diagnostic)
    }

    // MARK: - Read-only diagnostics

    internal static func coreDiagnosticKind(_ raw: Int) -> ProducerDiagnostic.Kind {
        switch raw {
        case 0: return .attemptFinished
        case 1: return .retryScheduled
        case 2: return .batchRetained
        case 3: return .batchTerminal
        case 4: return .batchSealed
        case 5: return .attemptStarted
        default: return .unknown
        }
    }

    internal static func diagnostic(from fields: [String: Any]) -> ProducerDiagnostic {
        var context = ProducerDiagnosticDetails(nativeFields: fields as NSDictionary)
        context.source = fields["source"] as? String
        if let counters = fields["counters"] as? [String: Any] {
            context.attemptCount = (counters["attempt_count"] as? NSNumber)?.intValue
            context.cycleAttemptCount = (counters["cycle_attempt_count"] as? NSNumber)?.intValue
            context.logCount = (counters["log_count"] as? NSNumber)?.intValue
        }
        let kind: ProducerDiagnostic.Kind
        let reason: ProducerDiagnostic.Reason
        if context.source == "core" {
            kind = coreDiagnosticKind((fields["core_event"] as? NSNumber)?.intValue ?? -1)
            switch (fields["core_reason"] as? NSNumber)?.intValue {
            case 0: reason = .none
            case 1: reason = .success
            case 2: reason = .nonRetryable
            case 3: reason = .maxAttempts
            case 4: reason = .retryBudget
            case 5: reason = .retentionExpired
            case 6: reason = .closed
            default: reason = .unknown
            }
            if let code = context.transportCode, code != 0 { context.transportKind = "generic" }
            // Core's legacy diagnostic has a numeric transport code but no
            // NSError namespace. The correlated transport event owns that
            // information; do not infer a namespace from the number's sign.
            if kind == .batchSealed || kind == .attemptStarted { context.retryable = nil; context.transportCode = nil }
        } else if context.source == "lifecycle" {
            kind = .lifecycle
            reason = context.reason == "expiration" ? .unknown : .none
        } else {
            kind = fields["event"] as? String == "transport_metrics" ? .transportMetrics : .transportFinished
            let failed = fields["error_domain"] is String || (context.httpCode ?? 0) >= 400
            reason = failed ? .unknown : .success
            context.transportKind = context.transportCode == nil ? nil : "generic"
            if let duration = fields["duration_ms"] as? NSNumber,
                duration.doubleValue.isFinite, duration.doubleValue >= 0,
                duration.doubleValue < Double(Int64.max) {
                context.attemptElapsedMs = Int64(duration.doubleValue.rounded())
            }
        }
        return ProducerDiagnostic(kind: kind, reason: reason,
            startID: context.batchStartID ?? 0, endID: context.batchEndID ?? 0,
            attemptCount: context.attemptCount ?? 0, cycleAttemptCount: context.cycleAttemptCount ?? 0,
            elapsed: Double(context.deliveryElapsedMs ?? 0) / 1000,
            retryDelay: Double(context.retryDelayMs ?? 0) / 1000,
            logCount: context.logCount ?? 0, rawBytes: context.rawBytes ?? 0,
            compressedBytes: context.compressedBytes ?? 0,
            httpCode: context.httpCode ?? 0, transportCode: context.transportCode ?? 0,
            retryable: context.retryable ?? false, requestID: context.requestID,
            errorCode: context.errorCode, context: context)
    }

    internal func readDiagnosticSnapshot() -> ProducerDiagnosticDetails? {
        guard diagnosticEmitter.isEnabled else { return nil }
        guard let fields = adapter.diagnosticSnapshot() else { return nil }
        var context = ProducerDiagnosticDetails(nativeFields: fields as NSDictionary)
        context.bufferLimitBytes = bufferLimitBytes
        context.automaticLifecycleHandling = automaticLifecycleHandling
        context.appState = withStateLock { diagnosticAppState }
        return context
    }

    private func startDiagnosticSampling() {
        guard diagnosticEmitter.isEnabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
            label: "com.volcengine.tls.producer.diagnostic-sampling", qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, !self.withStateLock({ self.diagnosticSamplingStopped }) else { return }
            self.diagnosticEmitter.admissionSummary(nativeFields: self.readDiagnosticSnapshot())
        }
        withStateLock { diagnosticTimer = timer }
        timer.resume()
    }

    private func stopDiagnosticSampling() {
        let timer = withStateLock { () -> DispatchSourceTimer? in
            diagnosticSamplingStopped = true
            let timer = diagnosticTimer
            diagnosticTimer = nil
            return timer
        }
        timer?.cancel()
    }

    // MARK: - Lifecycle

    private func installLifecycleManagerIfNeeded() {
#if os(iOS)
        guard automaticLifecycleHandling else { return }
        runOnMainSync {
            guard self.lifecycleManager == nil else { return }
            self.lifecycleManager = TLSLifecycleManager(
                flushHandler: { [weak self = self] in self?.adapter.flush() },
                wakeHandler: { [weak self = self] in
                    self?.adapter.flush()
                    self?.adapter.notifyNetworkRecovered()
                },
                host: TLSDefaultLifecycleHost(), extensionCheck: nil,
                observer: self.diagnosticEmitter.isEnabled ? { [weak self = self] fields in
                    guard let self else { return }
                    let diagnostic = RealCoreAdapter.diagnostic(from: fields)
                    self.withStateLock { self.diagnosticAppState = diagnostic.context?.appState ?? "unknown" }
                    self.diagnosticEmitter.offer(diagnostic)
                } : nil)
        }
#endif
    }

    private func removeLifecycleManager() {
#if os(iOS)
        guard lifecycleManager != nil else { return }
        runOnMainSync { self.lifecycleManager = nil }
#endif
    }

    private func transferLifecycleManagerReleaseToMainThread() {
        guard let manager = lifecycleManager else { return }
        lifecycleManager = nil
        if Thread.isMainThread {
            _ = manager
        } else {
            DispatchQueue.main.async { _ = manager }
        }
    }

    private func runOnMainSync(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    // MARK: - Error mapping

    private static func mapBridgeError(
        _ error: Error,
        operation: Operation
    ) -> ProducerError {
        if let producerError = error as? ProducerError {
            return producerError
        }
        let nsError = error as NSError
        if nsError.domain == TLSProducerDirectoryErrorDomain {
            return .persistence("producer directory operation failed")
        }
        guard nsError.domain == TLSRealCoreAdapterErrorDomain else {
            return .internal("adapter operation failed")
        }

        let resultValue = (nsError.userInfo[TLSRealCoreAdapterErrorResultKey] as? NSNumber)?
            .intValue
        let result = resultValue.flatMap(CoreResult.init(rawValue:))
        switch result {
        case .closed:
            return .closed
        case .timeout:
            return .timeout
        case .persistence:
            return .persistence("persistent Core operation failed")
        case .dropped where operation == .add:
            // v0.3.1 exposes one admission DROP result for both queue and
            // byte-budget exhaustion; classify conservatively as bufferFull.
            return .bufferFull
        case .invalid:
            return operation == .open
                ? .configuration("C Core rejected the configuration")
                : .internal("C Core rejected a validated operation")
        case .ok, .dropped, .none:
            break
        }

        if nsError.code == TLSRealCoreAdapterErrorCode.closed.rawValue {
            return .closed
        }
        if nsError.code == TLSRealCoreAdapterErrorCode.recoveryFailed.rawValue {
            return .persistence("persistent recovery failed")
        }
        if nsError.code == TLSRealCoreAdapterErrorCode.closeFailed.rawValue,
           operation == .close {
            return .internal("C Core close failed")
        }
        return .internal("C Core adapter operation failed")
    }

    static func mapSendFailure(
        result: Int32,
        httpCode: Int,
        errorCode: String?,
        errorMessage: String?,
        requestID: String?,
        transportKind: Int,
        transportCode: Int,
        retryable: Bool
    ) -> ProducerError? {
        guard result != CoreResult.ok.rawValue else { return nil }

        if isAuthenticationErrorCode(errorCode) {
            return .auth
        }

        switch httpCode {
        case 401, 403:
            return .auth
        case 429:
            return .quota
        case let code where code > 0:
            return .service(
                code: code,
                message: errorCode ?? errorMessage ?? "service request failed",
                requestID: requestID)
        default:
            break
        }

        // The current C Core uses VE_TLS_TRANSPORT_GENERIC for some errors
        // produced before the HTTP adapter is entered. A zero transport code
        // plus one of these stable Core codes is therefore a local lifecycle,
        // capacity, or invariant failure—not a DNS/TLS/connect failure.
        // Classify it before the transport-kind fallback so public results do
        // not hide PayloadTooLarge/queue/buffer failures as `transport`.
        if transportCode == 0 {
            let normalized = errorCode?.lowercased() ?? ""
            switch normalized {
            case "retrybudgetexceeded", "retryretentionexpired":
                return .timeout
            case "producerclosed", "sendqueuestopped":
                return .closed
            case "keyqueuelimitexceeded", "sendqueuefull", "sendqueuetimeout":
                return .queueFull
            case "bufferfull", "bufferfulltimeout":
                return .bufferFull
            case "payloadtoolarge":
                return .internal("C Core rejected a validated batch size")
            case "outofmemory":
                return .internal("C Core could not retain a pending batch")
            case "memoryallocfailed", "clienterror", "credentialsrefreshfailed":
                return .internal("C Core failed before starting the HTTP request")
            default:
                break
            }
        }

        if result == CoreResult.timeout.rawValue || (transportCode == 2103 || transportCode == NSURLErrorTimedOut) {
            return .timeout
        }
        if transportCode == 2104 {
            return .cancelled
        }
        if transportKind != 0 {
            _ = retryable // retained for future public retry-state expansion
            return .transport(errorMessage ?? "HTTP transport failed")
        }

        switch CoreResult(rawValue: Int(result)) {
        case .persistence:
            return .persistence("persistent send failed")
        case .closed:
            return .closed
        case .dropped:
            let normalized = errorCode?.lowercased() ?? ""
            if normalized.contains("queue") { return .queueFull }
            if normalized.contains("persist") {
                return .persistence("persistent send failed")
            }
            return .bufferFull
        case .invalid:
            return .internal("C Core rejected a validated batch")
        case .timeout:
            return .timeout
        case .ok, .none:
            return .internal("C Core send failed")
        }
    }

    private static func isAuthenticationErrorCode(_ errorCode: String?) -> Bool {
        switch errorCode?.lowercased() {
        case "credentialsrefreshfailed",
             "expiredtoken",
             "invalidsecuritytoken",
             "authfailed",
             "signaturedoesnotmatch",
             "accessdenied":
            return true
        default:
            return false
        }
    }
}
