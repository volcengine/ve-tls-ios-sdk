import Foundation

/// Converts a typed diagnostic into the bounded, single-line JSON contract.
///
/// The formatter only accepts values from `ProducerDiagnostic` and
/// `ProducerDiagnosticDetails`. It never serializes an NSError, URL, request
/// body, header, credential, or arbitrary error message.
internal enum DiagnosticFormatter {
    internal static let maxUTF8Bytes = 4_096

    /// Formats a diagnostic. `context` is merged over the event's context;
    /// occurrence fields supplied by the emitter therefore win over stale
    /// values from a producer/core callback.
    internal static func format(
        _ diagnostic: ProducerDiagnostic,
        level: ProducerDiagnosticLogLevel? = nil,
        sequence: Int64? = nil,
        timeMs: Int64? = nil,
        source: String? = nil,
        context: ProducerDiagnosticDetails? = nil,
        textSuppressedTotal: Int64? = nil,
        textSuppressedSinceReport: Int64? = nil
    ) -> String? {
        let merged = (diagnostic.context ?? ProducerDiagnosticDetails())
            .merging(context ?? ProducerDiagnosticDetails())
        return serialize(
            diagnostic: diagnostic,
            context: sanitized(merged),
            level: level,
            sequence: sequence,
            timeMs: timeMs,
            source: source,
            textSuppressedTotal: textSuppressedTotal,
            textSuppressedSinceReport: textSuppressedSinceReport)
    }

    /// A convenience used by tests and by adapters that already have all
    /// occurrence metadata in one value.
    internal static func format(
        diagnostic: ProducerDiagnostic,
        context: ProducerDiagnosticDetails
    ) -> String? {
        format(diagnostic, context: context)
    }

    internal static func eventLevel(for diagnostic: ProducerDiagnostic) -> ProducerDiagnosticLogLevel {
        switch diagnostic.kind {
        case .openStarted, .opened, .admissionSummary, .closed, .closeStarted:
            return .info
        case .openFailed:
            return .error
        case .closeFailed, .diagnosticsDropped:
            return .warning
        case .admissionRejected, .batchRetained:
            return .warning
        case .batchSealed, .attemptStarted, .retryScheduled, .transportMetrics:
            return .debug
        case .attemptFinished:
            return diagnostic.reason == .success ? .debug : .warning
        case .batchTerminal:
            return diagnostic.reason == .success ? .info : .error
        case .transportFinished:
            return diagnostic.reason == .success ? .debug : .warning
        case .lifecycle:
            return diagnostic.reason == .success || diagnostic.reason == .none
                ? .info
                : .warning
        case .unknown:
            return .warning
        }
    }

    /// Sanitizes typed context before structured delivery. This is separate
    /// from JSON formatting because structured clients receive the DTO too.
    internal static func sanitizeContext(_ value: ProducerDiagnosticDetails) -> ProducerDiagnosticDetails {
        sanitized(value)
    }

    // MARK: - JSON construction

    private static func serialize(
        diagnostic: ProducerDiagnostic,
        context: ProducerDiagnosticDetails,
        level: ProducerDiagnosticLogLevel?,
        sequence: Int64?,
        timeMs: Int64?,
        source: String?,
        textSuppressedTotal: Int64?,
        textSuppressedSinceReport: Int64?
    ) -> String? {
        // `.off` is a text-handler configuration value, never an event level.
        let eventLevel = (level == .off ? nil : level)
            ?? context.level
            ?? eventLevel(for: diagnostic)
        let eventSource = safeSource(context.source ?? source) ?? "producer"
        let eventTime = context.timeMs ?? timeMs
        let eventSequence = context.sequence ?? sequence

        var object = makeObject(
            diagnostic: diagnostic,
            context: context,
            level: eventLevel,
            sequence: eventSequence,
            timeMs: eventTime,
            source: eventSource,
            fieldsOmitted: context.fieldsOmitted ?? false,
            includeOptionalDetails: true,
            textSuppressedTotal: textSuppressedTotal,
            textSuppressedSinceReport: textSuppressedSinceReport)
        if let data = jsonData(object), data.count <= maxUTF8Bytes {
            return String(data: data, encoding: .utf8)
        }

        // Prefer removing optional details while retaining the event identity,
        // legacy counters and occurrence metadata. This makes a long but
        // valid diagnostic observable without cutting a JSON string or a
        // UTF-8 sequence in half.
        var reduced = context
        reduced.clearOptionalDetails()
        reduced.fieldsOmitted = true
        object = makeObject(
            diagnostic: diagnostic,
            context: reduced,
            level: eventLevel,
            sequence: eventSequence,
            timeMs: eventTime,
            source: eventSource,
            fieldsOmitted: true,
            includeOptionalDetails: false,
            textSuppressedTotal: textSuppressedTotal,
            textSuppressedSinceReport: textSuppressedSinceReport)
        if let data = jsonData(object), data.count <= maxUTF8Bytes {
            return String(data: data, encoding: .utf8)
        }

        // The fixed string fields are already bounded. A caller can still
        // supply many valid optional identifiers, so clear those values as a
        // final omission step. A message that cannot fit after this step is
        // rejected rather than truncated into invalid JSON.
        reduced.clearOptionalIdentityStrings()
        object = makeObject(
            diagnostic: diagnostic,
            context: reduced,
            level: eventLevel,
            sequence: eventSequence,
            timeMs: eventTime,
            source: eventSource,
            fieldsOmitted: true,
            includeOptionalDetails: false,
            textSuppressedTotal: textSuppressedTotal,
            textSuppressedSinceReport: textSuppressedSinceReport)
        guard let data = jsonData(object), data.count <= maxUTF8Bytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func makeObject(
        diagnostic: ProducerDiagnostic,
        context: ProducerDiagnosticDetails,
        level: ProducerDiagnosticLogLevel,
        sequence: Int64?,
        timeMs: Int64?,
        source: String,
        fieldsOmitted: Bool,
        includeOptionalDetails: Bool,
        textSuppressedTotal: Int64?,
        textSuppressedSinceReport: Int64?
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        func put(_ key: String, _ value: Any?) {
            guard let value, !(value is NSNull) else { return }
            if let string = value as? String, string.isEmpty { return }
            // The rejection map is the formatter's only collection value.
            if let counts = value as? [String: Int64], counts.isEmpty { return }
            result[key] = value
        }
        func putMeaningfulMarker(_ key: String, _ value: Any?) {
            if let marker = value as? String {
                switch key {
                case "reason", "disposition", "app_state", "timeout_source", "cancel_source":
                    if marker == "none" || marker == "unknown" { return }
                default:
                    break
                }
            }
            put(key, value)
        }
        func positiveOrNil(_ value: Int) -> Int? { value > 0 ? value : nil }
        func positiveOrNil(_ value: Int64) -> Int64? { value > 0 ? value : nil }
        func milliseconds(_ value: TimeInterval) -> Int64? {
            guard value.isFinite, value > 0 else { return nil }
            let milliseconds = value * 1_000
            guard milliseconds.isFinite, milliseconds >= 1,
                  milliseconds <= Double(Int64.max) else { return nil }
            return Int64(milliseconds.rounded())
        }
        let legacyCoreFieldsKnown = Self.legacyCoreFieldsKnown(diagnostic)

        put("schema_version", context.schemaVersion ?? 1)
        put("event", context.event ?? diagnostic.kind.eventName)
        put("level", level.rawValue)
        put("source", source)
        put("time_ms", timeMs)
        put("sequence", sequence)
        put("sdk_version", context.sdkVersion)
        put("producer_instance_id", context.producerInstanceID)
        put("producer_id", context.producerID)
        put("topic_id", context.topicID)
        put("endpoint_host", context.endpointHost)

        put("batch_start_id", context.batchStartID ?? (legacyCoreFieldsKnown ? positiveOrNil(diagnostic.startID) : nil))
        put("batch_end_id", context.batchEndID ?? (legacyCoreFieldsKnown ? positiveOrNil(diagnostic.endID) : nil))
        put("log_count", context.logCount ?? (legacyCoreFieldsKnown ? positiveOrNil(diagnostic.logCount) : nil))
        put("attempt_count", context.attemptCount ?? (legacyCoreFieldsKnown ? positiveOrNil(diagnostic.attemptCount) : nil))
        put("cycle_attempt_count", context.cycleAttemptCount ?? (legacyCoreFieldsKnown ? positiveOrNil(diagnostic.cycleAttemptCount) : nil))
        put("raw_bytes", context.rawBytes ?? (legacyCoreFieldsKnown ? positiveOrNil(diagnostic.rawBytes) : nil))
        put("compressed_bytes", context.compressedBytes ?? (legacyCoreFieldsKnown ? positiveOrNil(diagnostic.compressedBytes) : nil))
        put("delivery_elapsed_ms", context.deliveryElapsedMs ?? (legacyCoreFieldsKnown ? milliseconds(diagnostic.elapsed) : nil))
        put("retry_delay_ms", context.retryDelayMs ?? (legacyCoreFieldsKnown ? milliseconds(diagnostic.retryDelay) : nil))
        put("attempt_elapsed_ms", context.attemptElapsedMs)
        put("queue_wait_ms", context.queueWaitMs)

        // HTTP code zero is a meaningful no-response sentinel. Transport code
        // zero is likewise retained because the existing field distinguishes
        // HTTP outcomes from native transport failures by namespace.
        put("http_code", context.httpCode ?? (legacyCoreFieldsKnown ? diagnostic.httpCode : nil))
        put("request_id", context.requestID ?? (legacyCoreFieldsKnown
            ? DiagnosticFieldPolicy.requestID(diagnostic.requestID)
            : nil))
        put("error_code", context.errorCode ?? DiagnosticFieldPolicy.token(diagnostic.errorCode))
        put("producer_error_domain", context.producerErrorDomain)
        put("producer_error_code", context.producerErrorCode)
        put("producer_error_name", context.producerErrorName)
        put("admission_stage", context.admissionStage)
        put("transport_kind", context.transportKind)
        put("transport_error_domain", context.transportErrorDomain)
        let legacyTransportCode: Int? = legacyCoreFieldsKnown &&
            (diagnostic.transportCode != 0 || diagnostic.httpCode > 0)
            ? diagnostic.transportCode
            : nil
        put("transport_code", context.transportCode ?? legacyTransportCode)
        put("underlying_error_domain", context.underlyingErrorDomain)
        put("underlying_error_code", context.underlyingErrorCode)
        put("retryable", context.retryable ?? (legacyCoreFieldsKnown ? diagnostic.retryable : nil))
        putMeaningfulMarker("reason", context.reason ?? diagnostic.reason.diagnosticName)
        putMeaningfulMarker("disposition", context.disposition)
        putMeaningfulMarker("timeout_source", context.timeoutSource)
        putMeaningfulMarker("cancel_source", context.cancelSource)
        putMeaningfulMarker("app_state", context.appState)
        put("automatic_lifecycle_handling", context.automaticLifecycleHandling)
        put("buffer_used_bytes", context.bufferUsedBytes)
        put("buffer_limit_bytes", context.bufferLimitBytes)

        if includeOptionalDetails {
            put("attempt_id", context.attemptID)
            put("sent_body_bytes", context.sentBodyBytes)
            put("expected_body_bytes", context.expectedBodyBytes)
            put("dns_ms", context.dnsMs)
            put("connection_setup_ms", context.connectionSetupMs)
            put("tls_handshake_ms", context.tlsHandshakeMs)
            put("request_send_ms", context.requestSendMs)
            put("response_wait_ms", context.responseWaitMs)
            put("response_read_ms", context.responseReadMs)
            put("network_protocol", context.networkProtocol)
            put("connection_reused", context.connectionReused)

            put("batch_count", context.batchCount)
            put("batch_raw_bytes", context.batchRawBytes)
            put("linger_ms", context.lingerMs)
            put("send_concurrency", context.sendConcurrency)
            put("compression", context.compression)
            put("persistence_mode", context.persistenceMode)
            put("connect_timeout_ms", context.connectTimeoutMs)
            put("request_timeout_ms", context.requestTimeoutMs)
            put("request_idle_timeout_ms", context.requestIdleTimeoutMs)
            put("retry_max_attempts", context.retryMaxAttempts)
            put("retry_total_timeout_ms", context.retryTotalTimeoutMs)
            put("retry_initial_interval_ms", context.retryInitialIntervalMs)
            put("retry_max_interval_ms", context.retryMaxIntervalMs)
            put("memory_retry_retention_ms", context.memoryRetryRetentionMs)
            put("close_timeout_ms", context.closeTimeoutMs)

            put("add_attempted_total", context.addAttemptedTotal)
            put("add_accepted_total", context.addAcceptedTotal)
            put("add_rejected_by_error", sanitizedRejectionMap(context.addRejectedByError))
            put("core_logs_enqueued_total", context.coreLogsEnqueuedTotal)
            put("core_logs_dropped_total", context.coreLogsDroppedTotal)
            put("core_batches_built_total", context.coreBatchesBuiltTotal)
            put("core_requests_total", context.coreRequestsTotal)
            put("core_requests_failed_total", context.coreRequestsFailedTotal)
            put("core_retries_total", context.coreRetriesTotal)
            put("core_bytes_sent_total", context.coreBytesSentTotal)
            put("diagnostic_dropped_total", context.diagnosticDroppedTotal)
            put("diagnostic_dropped_since_last_report", context.diagnosticDroppedSinceLastReport)
        }
        if let textSuppressedTotal, textSuppressedTotal > 0 {
            put("text_suppressed_total", textSuppressedTotal)
        }
        if let textSuppressedSinceReport, textSuppressedSinceReport > 0 {
            put("text_suppressed_since_last_report", textSuppressedSinceReport)
        }
        if fieldsOmitted { result["fields_omitted"] = true }
        return result
    }

    private static func legacyCoreFieldsKnown(_ diagnostic: ProducerDiagnostic) -> Bool {
        switch diagnostic.kind {
        // Only the original Core delivery events carried the legacy scalar
        // fields. New observation events must use typed context; their
        // default retryable=false is not a classification.
        case .attemptFinished, .retryScheduled, .batchRetained, .batchTerminal:
            return true
        default:
            return false
        }
    }

    private static func jsonData(_ value: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func sanitizedRejectionMap(_ value: [String: Int64]?) -> [String: Int64]? {
        guard let value else { return nil }
        var result: [String: Int64] = [:]
        for (key, count) in value.prefix(32) {
            guard let safeKey = DiagnosticFieldPolicy.token(key), count >= 0 else { continue }
            result[safeKey] = count
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Field policy

    private static func sanitized(_ value: ProducerDiagnosticDetails) -> ProducerDiagnosticDetails {
        var result = value
        result.schemaVersion = result.schemaVersion == 1 ? 1 : nil
        result.event = DiagnosticFieldPolicy.token(result.event)
        if result.level == .off { result.level = nil }
        result.source = safeSource(result.source)
        result.sdkVersion = DiagnosticFieldPolicy.token(result.sdkVersion, maxBytes: 128)
        result.producerInstanceID = DiagnosticFieldPolicy.token(result.producerInstanceID)
        result.producerID = DiagnosticFieldPolicy.token(result.producerID)
        result.topicID = DiagnosticFieldPolicy.token(result.topicID)
        result.endpointHost = DiagnosticFieldPolicy.endpointHost(result.endpointHost)
        result.requestID = DiagnosticFieldPolicy.requestID(result.requestID)
        result.errorCode = DiagnosticFieldPolicy.token(result.errorCode)
        result.producerErrorDomain = DiagnosticFieldPolicy.token(result.producerErrorDomain)
        result.producerErrorName = DiagnosticFieldPolicy.token(result.producerErrorName)
        result.admissionStage = DiagnosticFieldPolicy.admissionStage(result.admissionStage)
        result.transportKind = DiagnosticFieldPolicy.token(result.transportKind)
        result.transportErrorDomain = DiagnosticFieldPolicy.token(result.transportErrorDomain)
        result.underlyingErrorDomain = DiagnosticFieldPolicy.token(result.underlyingErrorDomain)
        result.reason = DiagnosticFieldPolicy.token(result.reason)
        result.disposition = DiagnosticFieldPolicy.token(result.disposition)
        result.timeoutSource = DiagnosticFieldPolicy.token(result.timeoutSource)
        result.cancelSource = DiagnosticFieldPolicy.token(result.cancelSource)
        result.appState = DiagnosticFieldPolicy.token(result.appState)
        result.attemptID = DiagnosticFieldPolicy.token(result.attemptID)
        result.networkProtocol = DiagnosticFieldPolicy.token(result.networkProtocol)
        result.compression = DiagnosticFieldPolicy.token(result.compression)
        result.persistenceMode = DiagnosticFieldPolicy.token(result.persistenceMode)
        if let map = result.addRejectedByError {
            result.addRejectedByError = sanitizedRejectionMap(map)
        }
        return result
    }

    private static func safeSource(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value {
        case "facade", "producer", "core", "transport", "lifecycle": return value
        default: return nil
        }
    }
}

/// Shared string policy used by the emitter and formatter. It rejects a
/// value instead of truncating it, especially for RequestID where truncation
/// would create a different correlation identifier.
internal enum DiagnosticFieldPolicy {
    internal static let defaultMaxBytes = 256

    internal static func token(_ value: String?, maxBytes: Int = defaultMaxBytes) -> String? {
        guard let value, value.utf8.count <= maxBytes, !value.isEmpty else { return nil }
        let lowercased = value.lowercased()
        let sensitiveMarkers = [
            "secret", "password", "authorization", "bearer", "sessiontoken",
            "securitytoken", "accesskey", "access_key", "secretkey", "token=",
        ]
        guard !sensitiveMarkers.contains(where: { lowercased.contains($0) }) else {
            return nil
        }
        guard value.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 58, 95, 43, 47:
                return true
            default:
                return false
            }
        }) else { return nil }
        return value
    }

    internal static func requestID(_ value: String?) -> String? {
        // Request IDs are correlated as a complete value and therefore are
        // rejected rather than shortened when they exceed this bound.
        guard let value, value.utf8.count <= 256, !value.isEmpty else { return nil }
        guard value.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 58, 95:
                return true
            default:
                return false
            }
        }) else { return nil }
        return value
    }

    internal static func endpointHost(_ value: String?) -> String? {
        guard let value, value.utf8.count <= defaultMaxBytes else { return nil }
        if let components = URLComponents(string: value), components.host != nil {
            // Only the normalized host crosses the diagnostic boundary.
            // Userinfo, path, query and fragment are intentionally ignored,
            // so credentials or tokens in a malformed caller URL cannot be
            // copied into the event.
            guard components.scheme?.lowercased() == "https",
                  let host = components.host else { return nil }
            return sanitizeHost(host)
        }
        return sanitizeHost(value)
    }

    internal static func admissionStage(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value {
        case "facade_mode", "facade_log", "state", "log_validation",
             "size_validation", "core_add":
            return value
        default:
            return nil
        }
    }

    private static func sanitizeHost(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= defaultMaxBytes else { return nil }
        guard value.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 58:
                return true
            default:
                return false
            }
        }) else { return nil }
        return value.lowercased()
    }
}

private extension ProducerDiagnosticDetails {
    mutating func clearOptionalDetails() {
        admissionStage = nil
        attemptID = nil; sentBodyBytes = nil; expectedBodyBytes = nil
        dnsMs = nil; connectionSetupMs = nil; tlsHandshakeMs = nil; requestSendMs = nil
        responseWaitMs = nil; responseReadMs = nil; networkProtocol = nil
        connectionReused = nil; batchCount = nil; batchRawBytes = nil; lingerMs = nil
        sendConcurrency = nil; compression = nil; persistenceMode = nil
        connectTimeoutMs = nil; requestTimeoutMs = nil; requestIdleTimeoutMs = nil
        retryMaxAttempts = nil; retryTotalTimeoutMs = nil; retryInitialIntervalMs = nil
        retryMaxIntervalMs = nil; memoryRetryRetentionMs = nil
        addAttemptedTotal = nil; addAcceptedTotal = nil; addRejectedByError = nil
        coreLogsEnqueuedTotal = nil; coreLogsDroppedTotal = nil; coreBatchesBuiltTotal = nil
        coreRequestsTotal = nil; coreRequestsFailedTotal = nil; coreRetriesTotal = nil
        coreBytesSentTotal = nil; diagnosticDroppedTotal = nil
        diagnosticDroppedSinceLastReport = nil
    }

    mutating func clearOptionalIdentityStrings() {
        sdkVersion = nil; producerInstanceID = nil; producerID = nil
        topicID = nil; endpointHost = nil; attemptID = nil; requestID = nil
    }
}
