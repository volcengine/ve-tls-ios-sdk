import Foundation

/// Severity used by the optional text diagnostic adapter.
///
/// The raw values are part of the public contract. `off` is a configuration
/// value and is never used as the level of an emitted event.
public enum ProducerDiagnosticLogLevel: Int, Equatable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case off = 4
}

/// Typed, bounded diagnostic context.
///
/// Every property is optional because a diagnostic is deliberately allowed to
/// be emitted when only part of the native context is available. The emitter
/// and formatter sanitize string values before they cross the public callback
/// boundary; this type contains no free-form error-message field.
public struct ProducerDiagnosticDetails: Equatable, Sendable {
    public var schemaVersion: Int?
    public var event: String?
    public var level: ProducerDiagnosticLogLevel?
    public var source: String?
    public var timeMs: Int64?
    public var sequence: Int64?
    public var sdkVersion: String?
    public var producerInstanceID: String?
    public var producerID: String?
    public var topicID: String?
    public var endpointHost: String?

    public var batchStartID: Int64?
    public var batchEndID: Int64?
    public var logCount: Int?
    public var attemptCount: Int?
    public var cycleAttemptCount: Int?
    public var rawBytes: Int?
    public var compressedBytes: Int?
    public var deliveryElapsedMs: Int64?
    public var retryDelayMs: Int64?
    public var attemptElapsedMs: Int64?
    public var queueWaitMs: Int64?

    public var httpCode: Int?
    public var requestID: String?
    public var errorCode: String?
    public var producerErrorDomain: String?
    public var producerErrorCode: Int?
    public var producerErrorName: String?
    public var admissionStage: String?
    public var transportKind: String?
    public var transportErrorDomain: String?
    public var transportCode: Int?
    public var underlyingErrorDomain: String?
    public var underlyingErrorCode: Int?
    public var retryable: Bool?
    public var reason: String?
    public var disposition: String?
    public var timeoutSource: String?
    public var cancelSource: String?
    public var appState: String?
    public var automaticLifecycleHandling: Bool?
    public var bufferUsedBytes: Int64?
    public var bufferLimitBytes: Int64?

    // Request/transport correlation and scalar task metrics.
    public var attemptID: String?
    public var sentBodyBytes: Int64?
    public var expectedBodyBytes: Int64?
    public var dnsMs: Int64?
    public var connectionSetupMs: Int64?
    public var tlsHandshakeMs: Int64?
    public var requestSendMs: Int64?
    public var responseWaitMs: Int64?
    public var responseReadMs: Int64?
    public var networkProtocol: String?
    public var connectionReused: Bool?

    // The immutable configuration summary captured at open time.
    public var batchCount: Int?
    public var batchRawBytes: Int64?
    public var lingerMs: Int64?
    public var sendConcurrency: Int?
    public var compression: String?
    public var persistenceMode: String?
    public var connectTimeoutMs: Int64?
    public var requestTimeoutMs: Int64?
    public var requestIdleTimeoutMs: Int64?
    public var retryMaxAttempts: Int?
    public var retryTotalTimeoutMs: Int64?
    public var retryInitialIntervalMs: Int64?
    public var retryMaxIntervalMs: Int64?
    public var memoryRetryRetentionMs: Int64?
    public var closeTimeoutMs: Int64?

    // Facade/Core/emitter statistics. These are separate counters by design.
    public var addAttemptedTotal: Int64?
    public var addAcceptedTotal: Int64?
    public var addRejectedByError: [String: Int64]?
    public var coreLogsEnqueuedTotal: Int64?
    public var coreLogsDroppedTotal: Int64?
    public var coreBatchesBuiltTotal: Int64?
    public var coreRequestsTotal: Int64?
    public var coreRequestsFailedTotal: Int64?
    public var coreRetriesTotal: Int64?
    public var coreBytesSentTotal: Int64?
    public var diagnosticDroppedTotal: Int64?
    public var diagnosticDroppedSinceLastReport: Int64?
    public var fieldsOmitted: Bool?

    public init() {}

    /// Copies only documented scalar fields from the native bridge snapshot.
    /// Unknown keys, objects and error payloads are ignored. This is an
    /// internal bridge seam so Objective-C adapters do not need to construct
    /// a free-form diagnostic dictionary in Swift.
    internal init(nativeFields: NSDictionary) {
        self.init()
        func number(_ keys: [String]) -> NSNumber? {
            for key in keys {
                if let value = nativeFields[key] as? NSNumber { return value }
            }
            return nil
        }
        func int(_ keys: [String]) -> Int? { number(keys).map { $0.intValue } }
        func int64(_ keys: [String]) -> Int64? { number(keys).map { $0.int64Value } }
        func bool(_ keys: [String]) -> Bool? { number(keys).map { $0.boolValue } }
        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = nativeFields[key] as? String { return value }
            }
            return nil
        }

        schemaVersion = int(["schema_version", "schemaVersion"])
        event = string(["event"])
        if let rawLevel = int(["level"]),
           let level = ProducerDiagnosticLogLevel(rawValue: rawLevel) {
            self.level = level == .off ? nil : level
        }
        source = string(["source"])
        timeMs = int64(["time_ms", "timeMs"])
        sequence = int64(["sequence"])
        sdkVersion = string(["sdk_version", "sdkVersion"])
        producerInstanceID = string(["producer_instance_id", "producerInstanceID"])
        producerID = string(["producer_id", "producerID"])
        topicID = string(["topic_id", "topicID"])
        endpointHost = string(["endpoint_host", "endpointHost"])
        batchStartID = int64(["batch_start_id", "batchStartID"])
        batchEndID = int64(["batch_end_id", "batchEndID"])
        logCount = int(["log_count", "logCount"])
        attemptCount = int(["attempt_count", "attemptCount"])
        cycleAttemptCount = int(["cycle_attempt_count", "cycleAttemptCount"])
        rawBytes = int(["raw_bytes", "rawBytes"])
        compressedBytes = int(["compressed_bytes", "compressedBytes"])
        deliveryElapsedMs = int64(["delivery_elapsed_ms", "deliveryElapsedMs"])
        retryDelayMs = int64(["retry_delay_ms", "retryDelayMs"])
        attemptElapsedMs = int64(["attempt_elapsed_ms", "attemptElapsedMs"])
        queueWaitMs = int64(["queue_wait_ms", "queueWaitMs"])
        httpCode = int(["http_code", "httpCode"])
        requestID = string(["request_id", "requestID"])
        errorCode = string(["error_code", "errorCode"])
        producerErrorDomain = string(["producer_error_domain", "producerErrorDomain"])
        producerErrorCode = int(["producer_error_code", "producerErrorCode"])
        producerErrorName = string(["producer_error_name", "producerErrorName"])
        admissionStage = string(["admission_stage", "admissionStage"])
        transportKind = string(["transport_kind", "transportKind"])
        transportErrorDomain = string(["transport_error_domain", "transportErrorDomain"])
        transportCode = int(["transport_code", "transportCode"])
        underlyingErrorDomain = string(["underlying_error_domain", "underlyingErrorDomain"])
        underlyingErrorCode = int(["underlying_error_code", "underlyingErrorCode"])
        retryable = bool(["retryable"])
        reason = string(["reason"])
        disposition = string(["disposition"])
        timeoutSource = string(["timeout_source", "timeoutSource"])
        cancelSource = string(["cancel_source", "cancelSource"])
        appState = string(["app_state", "appState"])
        automaticLifecycleHandling = bool([
            "automatic_lifecycle_handling", "automaticLifecycleHandling",
        ])
        bufferUsedBytes = int64(["buffer_used_bytes", "bufferUsedBytes"])
        bufferLimitBytes = int64(["buffer_limit_bytes", "bufferLimitBytes"])
        attemptID = string(["attempt_id", "attemptID"])
        sentBodyBytes = int64(["sent_body_bytes", "sentBodyBytes"])
        expectedBodyBytes = int64(["expected_body_bytes", "expectedBodyBytes"])
        dnsMs = int64(["dns_ms", "dnsMs"])
        connectionSetupMs = int64(["connection_setup_ms", "connectionSetupMs"])
        tlsHandshakeMs = int64(["tls_handshake_ms", "tlsHandshakeMs"])
        requestSendMs = int64(["request_send_ms", "requestSendMs"])
        responseWaitMs = int64(["response_wait_ms", "responseWaitMs"])
        responseReadMs = int64(["response_read_ms", "responseReadMs"])
        networkProtocol = string(["network_protocol", "networkProtocol"])
        connectionReused = bool(["connection_reused", "connectionReused"])
        batchCount = int(["batch_count", "batchCount"])
        batchRawBytes = int64(["batch_raw_bytes", "batchRawBytes"])
        lingerMs = int64(["linger_ms", "lingerMs"])
        sendConcurrency = int(["send_concurrency", "sendConcurrency"])
        compression = string(["compression"])
        persistenceMode = string(["persistence_mode", "persistenceMode"])
        connectTimeoutMs = int64(["connect_timeout_ms", "connectTimeoutMs"])
        requestTimeoutMs = int64(["request_timeout_ms", "requestTimeoutMs"])
        requestIdleTimeoutMs = int64(["request_idle_timeout_ms", "requestIdleTimeoutMs"])
        retryMaxAttempts = int(["retry_max_attempts", "retryMaxAttempts"])
        retryTotalTimeoutMs = int64(["retry_total_timeout_ms", "retryTotalTimeoutMs"])
        retryInitialIntervalMs = int64(["retry_initial_interval_ms", "retryInitialIntervalMs"])
        retryMaxIntervalMs = int64(["retry_max_interval_ms", "retryMaxIntervalMs"])
        memoryRetryRetentionMs = int64([
            "memory_retry_retention_ms", "memoryRetryRetentionMs",
        ])
        closeTimeoutMs = int64(["close_timeout_ms", "closeTimeoutMs"])
        addAttemptedTotal = int64(["add_attempted_total", "addAttemptedTotal"])
        addAcceptedTotal = int64(["add_accepted_total", "addAcceptedTotal"])
        coreLogsEnqueuedTotal = int64(["core_logs_enqueued_total", "coreLogsEnqueuedTotal"])
        coreLogsDroppedTotal = int64(["core_logs_dropped_total", "coreLogsDroppedTotal"])
        coreBatchesBuiltTotal = int64(["core_batches_built_total", "coreBatchesBuiltTotal"])
        coreRequestsTotal = int64(["core_requests_total", "coreRequestsTotal"])
        coreRequestsFailedTotal = int64([
            "core_requests_failed_total", "coreRequestsFailedTotal",
        ])
        coreRetriesTotal = int64(["core_retries_total", "coreRetriesTotal"])
        coreBytesSentTotal = int64(["core_bytes_sent_total", "coreBytesSentTotal"])
        diagnosticDroppedTotal = int64([
            "diagnostic_dropped_total", "diagnosticDroppedTotal",
        ])
        diagnosticDroppedSinceLastReport = int64([
            "diagnostic_dropped_since_last_report", "diagnosticDroppedSinceLastReport",
        ])
        fieldsOmitted = bool(["fields_omitted", "fieldsOmitted"])
        if let map = nativeFields["add_rejected_by_error"] as? NSDictionary {
            var values: [String: Int64] = [:]
            for (key, value) in map {
                guard let key = key as? String, let value = value as? NSNumber else { continue }
                values[key] = value.int64Value
            }
            addRejectedByError = values.isEmpty ? nil : values
        }
    }

    /// Returns a value in which non-nil fields from `overlay` replace the
    /// corresponding fields in this value. It is intentionally internal so
    /// the emitter can add occurrence metadata without exposing a dictionary
    /// merge API to clients.
    internal func merging(_ overlay: ProducerDiagnosticDetails) -> ProducerDiagnosticDetails {
        var value = self
        func replace<T>(_ source: T?, _ destination: inout T?) {
            if let source { destination = source }
        }
        replace(overlay.schemaVersion, &value.schemaVersion)
        replace(overlay.event, &value.event)
        replace(overlay.level, &value.level)
        replace(overlay.source, &value.source)
        replace(overlay.timeMs, &value.timeMs)
        replace(overlay.sequence, &value.sequence)
        replace(overlay.sdkVersion, &value.sdkVersion)
        replace(overlay.producerInstanceID, &value.producerInstanceID)
        replace(overlay.producerID, &value.producerID)
        replace(overlay.topicID, &value.topicID)
        replace(overlay.endpointHost, &value.endpointHost)
        replace(overlay.batchStartID, &value.batchStartID)
        replace(overlay.batchEndID, &value.batchEndID)
        replace(overlay.logCount, &value.logCount)
        replace(overlay.attemptCount, &value.attemptCount)
        replace(overlay.cycleAttemptCount, &value.cycleAttemptCount)
        replace(overlay.rawBytes, &value.rawBytes)
        replace(overlay.compressedBytes, &value.compressedBytes)
        replace(overlay.deliveryElapsedMs, &value.deliveryElapsedMs)
        replace(overlay.retryDelayMs, &value.retryDelayMs)
        replace(overlay.attemptElapsedMs, &value.attemptElapsedMs)
        replace(overlay.queueWaitMs, &value.queueWaitMs)
        replace(overlay.httpCode, &value.httpCode)
        replace(overlay.requestID, &value.requestID)
        replace(overlay.errorCode, &value.errorCode)
        replace(overlay.producerErrorDomain, &value.producerErrorDomain)
        replace(overlay.producerErrorCode, &value.producerErrorCode)
        replace(overlay.producerErrorName, &value.producerErrorName)
        replace(overlay.admissionStage, &value.admissionStage)
        replace(overlay.transportKind, &value.transportKind)
        replace(overlay.transportErrorDomain, &value.transportErrorDomain)
        replace(overlay.transportCode, &value.transportCode)
        replace(overlay.underlyingErrorDomain, &value.underlyingErrorDomain)
        replace(overlay.underlyingErrorCode, &value.underlyingErrorCode)
        replace(overlay.retryable, &value.retryable)
        replace(overlay.reason, &value.reason)
        replace(overlay.disposition, &value.disposition)
        replace(overlay.timeoutSource, &value.timeoutSource)
        replace(overlay.cancelSource, &value.cancelSource)
        replace(overlay.appState, &value.appState)
        replace(overlay.automaticLifecycleHandling, &value.automaticLifecycleHandling)
        replace(overlay.bufferUsedBytes, &value.bufferUsedBytes)
        replace(overlay.bufferLimitBytes, &value.bufferLimitBytes)
        replace(overlay.attemptID, &value.attemptID)
        replace(overlay.sentBodyBytes, &value.sentBodyBytes)
        replace(overlay.expectedBodyBytes, &value.expectedBodyBytes)
        replace(overlay.dnsMs, &value.dnsMs)
        replace(overlay.connectionSetupMs, &value.connectionSetupMs)
        replace(overlay.tlsHandshakeMs, &value.tlsHandshakeMs)
        replace(overlay.requestSendMs, &value.requestSendMs)
        replace(overlay.responseWaitMs, &value.responseWaitMs)
        replace(overlay.responseReadMs, &value.responseReadMs)
        replace(overlay.networkProtocol, &value.networkProtocol)
        replace(overlay.connectionReused, &value.connectionReused)
        replace(overlay.batchCount, &value.batchCount)
        replace(overlay.batchRawBytes, &value.batchRawBytes)
        replace(overlay.lingerMs, &value.lingerMs)
        replace(overlay.sendConcurrency, &value.sendConcurrency)
        replace(overlay.compression, &value.compression)
        replace(overlay.persistenceMode, &value.persistenceMode)
        replace(overlay.connectTimeoutMs, &value.connectTimeoutMs)
        replace(overlay.requestTimeoutMs, &value.requestTimeoutMs)
        replace(overlay.requestIdleTimeoutMs, &value.requestIdleTimeoutMs)
        replace(overlay.retryMaxAttempts, &value.retryMaxAttempts)
        replace(overlay.retryTotalTimeoutMs, &value.retryTotalTimeoutMs)
        replace(overlay.retryInitialIntervalMs, &value.retryInitialIntervalMs)
        replace(overlay.retryMaxIntervalMs, &value.retryMaxIntervalMs)
        replace(overlay.memoryRetryRetentionMs, &value.memoryRetryRetentionMs)
        replace(overlay.closeTimeoutMs, &value.closeTimeoutMs)
        replace(overlay.addAttemptedTotal, &value.addAttemptedTotal)
        replace(overlay.addAcceptedTotal, &value.addAcceptedTotal)
        replace(overlay.addRejectedByError, &value.addRejectedByError)
        replace(overlay.coreLogsEnqueuedTotal, &value.coreLogsEnqueuedTotal)
        replace(overlay.coreLogsDroppedTotal, &value.coreLogsDroppedTotal)
        replace(overlay.coreBatchesBuiltTotal, &value.coreBatchesBuiltTotal)
        replace(overlay.coreRequestsTotal, &value.coreRequestsTotal)
        replace(overlay.coreRequestsFailedTotal, &value.coreRequestsFailedTotal)
        replace(overlay.coreRetriesTotal, &value.coreRetriesTotal)
        replace(overlay.coreBytesSentTotal, &value.coreBytesSentTotal)
        replace(overlay.diagnosticDroppedTotal, &value.diagnosticDroppedTotal)
        replace(overlay.diagnosticDroppedSinceLastReport, &value.diagnosticDroppedSinceLastReport)
        replace(overlay.fieldsOmitted, &value.fieldsOmitted)
        return value
    }
}

/// Opt-in delivery/admission diagnostics. Retained attempts are not terminal
/// send results. Batch identifiers are scoped to the producer's log-ID stream.
/// Fields never contain log contents, URLs, credentials or server messages.
public struct ProducerDiagnostic: Equatable, Sendable {
    public enum Kind: Int, Sendable {
        case unknown = -1
        case attemptFinished = 0
        case retryScheduled = 1
        case batchRetained = 2
        case batchTerminal = 3
        case admissionRejected = 4
        case opened = 5
        case closed = 6
        case openFailed = 7
        case openStarted = 8
        case admissionSummary = 9
        case batchSealed = 10
        case attemptStarted = 11
        case transportFinished = 12
        case transportMetrics = 13
        case lifecycle = 14
        case closeStarted = 15
        case closeFailed = 16
        case diagnosticsDropped = 17
    }
    public enum Reason: Int, Sendable {
        case unknown = -1
        case none = 0
        case success = 1
        case nonRetryable = 2
        case maxAttempts = 3
        case retryBudget = 4
        case retentionExpired = 5
        case closed = 6
    }
    public let kind: Kind
    public let reason: Reason
    public let startID: Int64
    public let endID: Int64
    public let attemptCount: Int
    public let cycleAttemptCount: Int
    public let elapsed: TimeInterval
    public let retryDelay: TimeInterval
    public let logCount: Int
    public let rawBytes: Int
    public let compressedBytes: Int
    /// Zero means no usable HTTP response was received.
    public let httpCode: Int
    /// Native transport error code when available; zero for HTTP outcomes.
    public let transportCode: Int
    /// Classification of the last failure, not a promise of another attempt.
    public let retryable: Bool
    public let requestID: String?
    public let errorCode: String?
    /// Safe typed context captured with the same event. Sequence and time are
    /// filled by `DiagnosticEmitter` at queue admission.
    public let context: ProducerDiagnosticDetails?

    internal init(kind: Kind, reason: Reason = .none, startID: Int64 = 0,
                  endID: Int64 = 0, attemptCount: Int = 0, cycleAttemptCount: Int = 0,
                  elapsed: TimeInterval = 0, retryDelay: TimeInterval = 0,
                  logCount: Int = 0, rawBytes: Int = 0, compressedBytes: Int = 0,
                  httpCode: Int = 0, transportCode: Int = 0, retryable: Bool = false,
                  requestID: String? = nil, errorCode: String? = nil,
                  context: ProducerDiagnosticDetails? = nil) {
        self.kind = kind; self.reason = reason
        self.startID = startID; self.endID = endID
        self.attemptCount = attemptCount; self.cycleAttemptCount = cycleAttemptCount
        self.elapsed = elapsed; self.retryDelay = retryDelay
        self.logCount = logCount; self.rawBytes = rawBytes
        self.compressedBytes = compressedBytes; self.httpCode = max(0, httpCode)
        self.transportCode = transportCode; self.retryable = retryable
        self.requestID = requestID; self.errorCode = errorCode
        self.context = context
    }
}

extension ProducerDiagnostic.Kind {
    internal var eventName: String {
        switch self {
        case .unknown: return "unknown"
        case .attemptFinished: return "attempt_finished"
        case .retryScheduled: return "retry_scheduled"
        case .batchRetained: return "batch_retained"
        case .batchTerminal: return "batch_terminal"
        case .admissionRejected: return "admission_rejected"
        case .opened: return "opened"
        case .closed: return "closed"
        case .openFailed: return "open_failed"
        case .openStarted: return "open_started"
        case .admissionSummary: return "admission_summary"
        case .batchSealed: return "batch_sealed"
        case .attemptStarted: return "attempt_started"
        case .transportFinished: return "transport_finished"
        case .transportMetrics: return "transport_metrics"
        case .lifecycle: return "lifecycle"
        case .closeStarted: return "close_started"
        case .closeFailed: return "close_failed"
        case .diagnosticsDropped: return "diagnostics_dropped"
        }
    }
}

extension ProducerDiagnostic.Reason {
    internal var diagnosticName: String {
        switch self {
        case .unknown: return "unknown"
        case .none: return "none"
        case .success: return "success"
        case .nonRetryable: return "non_retryable"
        case .maxAttempts: return "max_attempts"
        case .retryBudget: return "retry_budget"
        case .retentionExpired: return "retention_expired"
        case .closed: return "closed"
        }
    }
}

/// Foundation-only diagnostic payload for Objective-C consumers.
@objc(TLSProducerDiagnostic)
@objcMembers
public final class TLSProducerDiagnostic: NSObject, @unchecked Sendable {
    public let kind: Int
    public let reason: Int
    public let startID: Int64
    public let endID: Int64
    public let attemptCount: Int
    public let cycleAttemptCount: Int
    public let elapsed: TimeInterval
    public let retryDelay: TimeInterval
    public let logCount: Int
    public let rawBytes: Int
    public let compressedBytes: Int
    public let httpCode: Int
    public let transportCode: Int
    public let retryable: Bool
    public let requestID: String?
    public let errorCode: String?
    public let context: TLSProducerDiagnosticDetails?

    internal init(_ value: ProducerDiagnostic) {
        let safeContext = value.context.map {
            DiagnosticFormatter.sanitizeContext($0)
        }
        kind = value.kind.rawValue; reason = value.reason.rawValue
        startID = value.startID; endID = value.endID
        attemptCount = value.attemptCount; cycleAttemptCount = value.cycleAttemptCount
        elapsed = value.elapsed; retryDelay = value.retryDelay
        logCount = value.logCount; rawBytes = value.rawBytes
        compressedBytes = value.compressedBytes; httpCode = value.httpCode
        transportCode = value.transportCode; retryable = value.retryable
        requestID = DiagnosticFieldPolicy.requestID(value.requestID)
        errorCode = DiagnosticFieldPolicy.token(value.errorCode)
        context = safeContext.map { TLSProducerDiagnosticDetails($0) }
        super.init()
    }

    @available(*, unavailable, message: "TLSProducerDiagnostic objects are delivered by TLSProducer")
    public override init() {
        fatalError("TLSProducerDiagnostic objects are delivered by TLSProducer")
    }
}

/// Objective-C-safe view of `ProducerDiagnosticDetails`.
@objc(TLSProducerDiagnosticDetails)
@objcMembers
public final class TLSProducerDiagnosticDetails: NSObject, @unchecked Sendable {
    public let schemaVersion: NSNumber?
    public let event: String?
    public let level: NSNumber?
    public let source: String?
    public let timeMs: NSNumber?
    public let sequence: NSNumber?
    public let sdkVersion: String?
    public let producerInstanceID: String?
    public let producerID: String?
    public let topicID: String?
    public let endpointHost: String?
    public let batchStartID: NSNumber?
    public let batchEndID: NSNumber?
    public let logCount: NSNumber?
    public let attemptCount: NSNumber?
    public let cycleAttemptCount: NSNumber?
    public let rawBytes: NSNumber?
    public let compressedBytes: NSNumber?
    public let deliveryElapsedMs: NSNumber?
    public let retryDelayMs: NSNumber?
    public let attemptElapsedMs: NSNumber?
    public let queueWaitMs: NSNumber?
    public let httpCode: NSNumber?
    public let requestID: String?
    public let errorCode: String?
    public let producerErrorDomain: String?
    public let producerErrorCode: NSNumber?
    public let producerErrorName: String?
    public let admissionStage: String?
    public let transportKind: String?
    public let transportErrorDomain: String?
    public let transportCode: NSNumber?
    public let underlyingErrorDomain: String?
    public let underlyingErrorCode: NSNumber?
    public let retryable: NSNumber?
    public let reason: String?
    public let disposition: String?
    public let timeoutSource: String?
    public let cancelSource: String?
    public let appState: String?
    public let automaticLifecycleHandling: NSNumber?
    public let bufferUsedBytes: NSNumber?
    public let bufferLimitBytes: NSNumber?
    public let attemptID: String?
    public let sentBodyBytes: NSNumber?
    public let expectedBodyBytes: NSNumber?
    public let dnsMs: NSNumber?
    public let connectionSetupMs: NSNumber?
    public let tlsHandshakeMs: NSNumber?
    public let requestSendMs: NSNumber?
    public let responseWaitMs: NSNumber?
    public let responseReadMs: NSNumber?
    public let networkProtocol: String?
    public let connectionReused: NSNumber?
    public let batchCount: NSNumber?
    public let batchRawBytes: NSNumber?
    public let lingerMs: NSNumber?
    public let sendConcurrency: NSNumber?
    public let compression: String?
    public let persistenceMode: String?
    public let connectTimeoutMs: NSNumber?
    public let requestTimeoutMs: NSNumber?
    public let requestIdleTimeoutMs: NSNumber?
    public let retryMaxAttempts: NSNumber?
    public let retryTotalTimeoutMs: NSNumber?
    public let retryInitialIntervalMs: NSNumber?
    public let retryMaxIntervalMs: NSNumber?
    public let memoryRetryRetentionMs: NSNumber?
    public let closeTimeoutMs: NSNumber?
    public let addAttemptedTotal: NSNumber?
    public let addAcceptedTotal: NSNumber?
    public let addRejectedByError: [String: NSNumber]?
    public let coreLogsEnqueuedTotal: NSNumber?
    public let coreLogsDroppedTotal: NSNumber?
    public let coreBatchesBuiltTotal: NSNumber?
    public let coreRequestsTotal: NSNumber?
    public let coreRequestsFailedTotal: NSNumber?
    public let coreRetriesTotal: NSNumber?
    public let coreBytesSentTotal: NSNumber?
    public let diagnosticDroppedTotal: NSNumber?
    public let diagnosticDroppedSinceLastReport: NSNumber?
    public let fieldsOmitted: NSNumber?

    fileprivate init(_ value: ProducerDiagnosticDetails?) {
        guard let value else {
            schemaVersion = nil; event = nil; level = nil; source = nil
            timeMs = nil; sequence = nil; sdkVersion = nil
            producerInstanceID = nil; producerID = nil; topicID = nil; endpointHost = nil
            batchStartID = nil; batchEndID = nil; logCount = nil; attemptCount = nil
            cycleAttemptCount = nil; rawBytes = nil; compressedBytes = nil
            deliveryElapsedMs = nil; retryDelayMs = nil; attemptElapsedMs = nil; queueWaitMs = nil
            httpCode = nil; requestID = nil; errorCode = nil
            producerErrorDomain = nil; producerErrorCode = nil; producerErrorName = nil
            admissionStage = nil
            transportKind = nil; transportErrorDomain = nil; transportCode = nil
            underlyingErrorDomain = nil; underlyingErrorCode = nil; retryable = nil
            reason = nil; disposition = nil; timeoutSource = nil; cancelSource = nil
            appState = nil; automaticLifecycleHandling = nil; bufferUsedBytes = nil
            bufferLimitBytes = nil; attemptID = nil; sentBodyBytes = nil; expectedBodyBytes = nil
            dnsMs = nil; connectionSetupMs = nil; tlsHandshakeMs = nil; requestSendMs = nil
            responseWaitMs = nil; responseReadMs = nil; networkProtocol = nil
            connectionReused = nil; batchCount = nil; batchRawBytes = nil; lingerMs = nil
            sendConcurrency = nil; compression = nil; persistenceMode = nil
            connectTimeoutMs = nil; requestTimeoutMs = nil; requestIdleTimeoutMs = nil
            retryMaxAttempts = nil; retryTotalTimeoutMs = nil; retryInitialIntervalMs = nil
            retryMaxIntervalMs = nil; memoryRetryRetentionMs = nil; closeTimeoutMs = nil
            addAttemptedTotal = nil
            addAcceptedTotal = nil; addRejectedByError = nil; coreLogsEnqueuedTotal = nil
            coreLogsDroppedTotal = nil; coreBatchesBuiltTotal = nil; coreRequestsTotal = nil
            coreRequestsFailedTotal = nil; coreRetriesTotal = nil; coreBytesSentTotal = nil
            diagnosticDroppedTotal = nil; diagnosticDroppedSinceLastReport = nil
            fieldsOmitted = nil
            super.init()
            return
        }
        schemaVersion = value.schemaVersion.map(NSNumber.init)
        event = value.event; level = value.level.map { NSNumber(value: $0.rawValue) }
        source = value.source; timeMs = value.timeMs.map(NSNumber.init)
        sequence = value.sequence.map(NSNumber.init); sdkVersion = value.sdkVersion
        producerInstanceID = value.producerInstanceID; producerID = value.producerID
        topicID = value.topicID; endpointHost = value.endpointHost
        batchStartID = value.batchStartID.map(NSNumber.init); batchEndID = value.batchEndID.map(NSNumber.init)
        logCount = value.logCount.map(NSNumber.init); attemptCount = value.attemptCount.map(NSNumber.init)
        cycleAttemptCount = value.cycleAttemptCount.map(NSNumber.init)
        rawBytes = value.rawBytes.map(NSNumber.init); compressedBytes = value.compressedBytes.map(NSNumber.init)
        deliveryElapsedMs = value.deliveryElapsedMs.map(NSNumber.init)
        retryDelayMs = value.retryDelayMs.map(NSNumber.init)
        attemptElapsedMs = value.attemptElapsedMs.map(NSNumber.init)
        queueWaitMs = value.queueWaitMs.map(NSNumber.init)
        httpCode = value.httpCode.map(NSNumber.init); requestID = value.requestID; errorCode = value.errorCode
        producerErrorDomain = value.producerErrorDomain; producerErrorCode = value.producerErrorCode.map(NSNumber.init)
        producerErrorName = value.producerErrorName; admissionStage = value.admissionStage
        transportKind = value.transportKind
        transportErrorDomain = value.transportErrorDomain; transportCode = value.transportCode.map(NSNumber.init)
        underlyingErrorDomain = value.underlyingErrorDomain
        underlyingErrorCode = value.underlyingErrorCode.map(NSNumber.init)
        retryable = value.retryable.map(NSNumber.init); reason = value.reason; disposition = value.disposition
        timeoutSource = value.timeoutSource; cancelSource = value.cancelSource; appState = value.appState
        automaticLifecycleHandling = value.automaticLifecycleHandling.map(NSNumber.init)
        bufferUsedBytes = value.bufferUsedBytes.map(NSNumber.init); bufferLimitBytes = value.bufferLimitBytes.map(NSNumber.init)
        attemptID = value.attemptID; sentBodyBytes = value.sentBodyBytes.map(NSNumber.init)
        expectedBodyBytes = value.expectedBodyBytes.map(NSNumber.init); dnsMs = value.dnsMs.map(NSNumber.init)
        connectionSetupMs = value.connectionSetupMs.map(NSNumber.init)
        tlsHandshakeMs = value.tlsHandshakeMs.map(NSNumber.init); requestSendMs = value.requestSendMs.map(NSNumber.init)
        responseWaitMs = value.responseWaitMs.map(NSNumber.init); responseReadMs = value.responseReadMs.map(NSNumber.init)
        networkProtocol = value.networkProtocol; connectionReused = value.connectionReused.map(NSNumber.init)
        batchCount = value.batchCount.map(NSNumber.init); batchRawBytes = value.batchRawBytes.map(NSNumber.init)
        lingerMs = value.lingerMs.map(NSNumber.init); sendConcurrency = value.sendConcurrency.map(NSNumber.init)
        compression = value.compression; persistenceMode = value.persistenceMode
        connectTimeoutMs = value.connectTimeoutMs.map(NSNumber.init)
        requestTimeoutMs = value.requestTimeoutMs.map(NSNumber.init)
        requestIdleTimeoutMs = value.requestIdleTimeoutMs.map(NSNumber.init)
        retryMaxAttempts = value.retryMaxAttempts.map(NSNumber.init)
        retryTotalTimeoutMs = value.retryTotalTimeoutMs.map(NSNumber.init)
        retryInitialIntervalMs = value.retryInitialIntervalMs.map(NSNumber.init)
        retryMaxIntervalMs = value.retryMaxIntervalMs.map(NSNumber.init)
        memoryRetryRetentionMs = value.memoryRetryRetentionMs.map(NSNumber.init)
        closeTimeoutMs = value.closeTimeoutMs.map(NSNumber.init)
        addAttemptedTotal = value.addAttemptedTotal.map(NSNumber.init)
        addAcceptedTotal = value.addAcceptedTotal.map(NSNumber.init)
        addRejectedByError = value.addRejectedByError?.reduce(into: [:]) { result, pair in
            result[pair.key] = NSNumber(value: pair.value)
        }
        coreLogsEnqueuedTotal = value.coreLogsEnqueuedTotal.map(NSNumber.init)
        coreLogsDroppedTotal = value.coreLogsDroppedTotal.map(NSNumber.init)
        coreBatchesBuiltTotal = value.coreBatchesBuiltTotal.map(NSNumber.init)
        coreRequestsTotal = value.coreRequestsTotal.map(NSNumber.init)
        coreRequestsFailedTotal = value.coreRequestsFailedTotal.map(NSNumber.init)
        coreRetriesTotal = value.coreRetriesTotal.map(NSNumber.init)
        coreBytesSentTotal = value.coreBytesSentTotal.map(NSNumber.init)
        diagnosticDroppedTotal = value.diagnosticDroppedTotal.map(NSNumber.init)
        diagnosticDroppedSinceLastReport = value.diagnosticDroppedSinceLastReport.map(NSNumber.init)
        fieldsOmitted = value.fieldsOmitted.map(NSNumber.init)
        super.init()
    }
}
