import Foundation

/// Clock seam for deterministic emitter tests. Wall time is captured when an
/// event is offered; monotonic time is available to owner adapters that want
/// to put their own elapsed values into `ProducerDiagnosticDetails`.
internal struct DiagnosticEmitterClock: @unchecked Sendable {
    internal let wallMilliseconds: @Sendable () -> Int64
    internal let monotonicNanoseconds: @Sendable () -> UInt64

    internal init(
        wallMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        },
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.wallMilliseconds = wallMilliseconds
        self.monotonicNanoseconds = monotonicNanoseconds
    }
}

/// Internal, bounded delivery adapter shared by structured and text
/// diagnostics.
///
/// The queue is a lock-protected FIFO with one scheduled drain block. A slow
/// customer handler therefore creates at most `capacity` copied event values
/// in the emitter; it cannot create an unbounded chain of `DispatchQueue`
/// blocks. Customer handlers are always invoked on the emitter-owned serial
/// queue and never while the emitter lock is held.
internal final class DiagnosticEmitter: @unchecked Sendable {
    internal static let maximumCapacity = 1_024

    private struct QueuedEvent: @unchecked Sendable {
        let diagnostic: ProducerDiagnostic
        let sequence: Int64
        let timeMs: Int64
        let isDropSummary: Bool
    }

    private struct AdmissionState: @unchecked Sendable {
        var attempted: Int64 = 0
        var accepted: Int64 = 0
        var rejectedByError: [String: Int64] = [:]
    }

    /// A transport RequestID is correlated to a later Core event by the
    /// internal attempt ID. Keep only the already-sanitized identifier, the
    /// omission bit and an expiry timestamp; never retain a request/error/body
    /// object or a native callback payload.
    private struct RequestIDAssociation: @unchecked Sendable {
        let requestID: String?
        let fieldsOmitted: Bool
        let expiresAtNanoseconds: UInt64
    }

    private struct TransportRequestIDObservation: @unchecked Sendable {
        let attemptID: String?
        let requestID: String?
        let fieldsOmitted: Bool
    }

    private let lock = NSLock()
    private let structuredHandler: (@Sendable (ProducerDiagnostic) -> Void)?
    private let textHandler: (@Sendable (ProducerDiagnosticLogLevel, String) -> Void)?
    private let configuredLevel: ProducerDiagnosticLogLevel
    private let producerInstanceID: String?
    private let sdkVersion: String?
    private let source: String
    private let clock: DiagnosticEmitterClock
    private let capacity: Int
    private let queue: DispatchQueue

    private static let maxRequestIDAssociations = 128
    private static let requestIDAssociationTTLNanos: UInt64 = 30_000_000_000

    private var producerID: String?
    private var topicID: String?
    private var endpointHost: String?
    private var pending: [QueuedEvent] = []
    private var nextSequence: Int64 = 1
    private var admission = AdmissionState()
    private var droppedTotal: Int64 = 0
    private var droppedSinceLastReport: Int64 = 0
    private var draining = false
    private var requestIDAssociations: [String: RequestIDAssociation] = [:]
    private var requestIDAssociationOrder: [String] = []

    /// Creates an emitter. The optional `diagnosticQueue` is a test seam; the
    /// production owner should omit it so the emitter always owns a private
    /// serial queue. It is never used as the business callback queue.
    internal init(
        structuredHandler: (@Sendable (ProducerDiagnostic) -> Void)? = nil,
        textHandler: (@Sendable (ProducerDiagnosticLogLevel, String) -> Void)? = nil,
        level: ProducerDiagnosticLogLevel = .info,
        producerID: String? = nil,
        topicID: String? = nil,
        endpoint: String? = nil,
        producerInstanceID: String? = nil,
        sdkVersion: String? = nil,
        source: String = "producer",
        capacity: Int = DiagnosticEmitter.maximumCapacity,
        clock: DiagnosticEmitterClock = DiagnosticEmitterClock(),
        diagnosticQueue: DispatchQueue? = nil
    ) {
        self.structuredHandler = structuredHandler
        self.textHandler = textHandler
        self.configuredLevel = level
        self.clock = clock
        self.capacity = max(1, min(capacity, DiagnosticEmitter.maximumCapacity))
        self.source = Self.safeSource(source) ?? "producer"
        self.sdkVersion = DiagnosticFieldPolicy.token(sdkVersion, maxBytes: 128)
        self.producerInstanceID = DiagnosticFieldPolicy.token(
            producerInstanceID ?? UUID().uuidString)
        self.producerID = DiagnosticFieldPolicy.token(producerID)
        self.topicID = DiagnosticFieldPolicy.token(topicID)
        self.endpointHost = DiagnosticFieldPolicy.endpointHost(endpoint)
        self.queue = diagnosticQueue ?? DispatchQueue(
            label: "com.volcengine.tls.producer.diagnostics",
            qos: .utility)
    }

    /// Whether at least one callback can receive an event. Text `.off` does
    /// not disable an independently configured structured callback.
    internal var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.isEnabled(
            structuredHandler: structuredHandler,
            textHandler: textHandler,
            level: configuredLevel)
    }

    /// Offers a copied diagnostic. `false` means disabled or full;
    /// a full queue increments the emitter-only drop counter immediately.
    @discardableResult
    internal func offer(_ diagnostic: ProducerDiagnostic) -> Bool {
        guard Self.isEnabled(
            structuredHandler: structuredHandler,
            textHandler: textHandler,
            level: configuredLevel) else { return false }

        // Capture occurrence time before acquiring the admission lock. This
        // keeps customer code and wall-clock access out of the lock while the
        // value still represents offer time rather than drain time.
        let timeMs = clock.wallMilliseconds()
        let transportObservation = Self.transportRequestIDObservation(for: diagnostic)
        let transportNow = transportObservation?.attemptID == nil
            ? nil
            : clock.monotonicNanoseconds()
        let coreAttemptID = Self.coreAttemptID(for: diagnostic)
        let coreNow = coreAttemptID == nil ? nil : clock.monotonicNanoseconds()
        var scheduleDrain = false
        lock.lock()
        if let transportObservation,
           let attemptID = transportObservation.attemptID,
           let transportNow {
            rememberRequestIDAssociation(
                attemptID: attemptID,
                requestID: transportObservation.requestID,
                fieldsOmitted: transportObservation.fieldsOmitted,
                now: transportNow)
        }
        var admittedDiagnostic = diagnostic
        if let coreAttemptID,
           let coreNow {
            if let association = requestIDAssociation(for: coreAttemptID, now: coreNow) {
                admittedDiagnostic = Self.applying(association, to: admittedDiagnostic)
            } else {
                // Core's legacy request_id may already be normalized or
                // truncated for business compatibility. Without a live
                // transport association it is not safe to present it as a
                // complete diagnostic correlation ID.
                admittedDiagnostic = Self.clearingUnassociatedCoreRequestID(
                    admittedDiagnostic)
            }
        }
        guard pending.count < capacity else {
            droppedTotal += 1
            droppedSinceLastReport += 1
            lock.unlock()
            return false
        }
        let sequence = nextSequence
        nextSequence = nextSequence == Int64.max ? 1 : nextSequence + 1
        let destination = (producerID, topicID, endpointHost)
        pending.append(QueuedEvent(
            diagnostic: enrich(
                admittedDiagnostic,
                sequence: sequence,
                timeMs: timeMs,
                destination: destination),
            sequence: sequence,
            timeMs: timeMs,
            isDropSummary: false))
        if !draining {
            draining = true
            scheduleDrain = true
        }
        lock.unlock()

        if scheduleDrain {
            // Keep one strong drain block alive until the FIFO is empty. This
            // matters for open-failure paths where the owner may release its
            // local emitter immediately after scheduling `open_failed`.
            queue.async { [self] in self.drain() }
        }
        return true
    }

    /// Records the facade admission boundary. These counters are kept only
    /// while diagnostics are enabled and are emitted by `admissionSummary`.
    internal func recordAdmission(accepted: Bool, errorName: String? = nil) {
        lock.lock()
        guard Self.isEnabled(
                structuredHandler: structuredHandler,
                textHandler: textHandler,
                level: configuredLevel) else {
            lock.unlock()
            return
        }
        admission.attempted += 1
        if accepted {
            admission.accepted += 1
        } else if let safeName = DiagnosticFieldPolicy.token(errorName) {
            admission.rejectedByError[safeName, default: 0] += 1
        } else {
            admission.rejectedByError["unknown", default: 0] += 1
        }
        lock.unlock()
    }

    /// Offers an admission summary without starting a timer or reading Core.
    /// `nativeFields` is a copied scalar snapshot supplied by the owner.
    internal func admissionSummary(
        nativeFields: ProducerDiagnosticDetails? = nil
    ) {
        lock.lock()
        guard Self.isEnabled(
                structuredHandler: structuredHandler,
                textHandler: textHandler,
                level: configuredLevel) else {
            lock.unlock()
            return
        }
        var fields = nativeFields ?? ProducerDiagnosticDetails()
        fields.addAttemptedTotal = admission.attempted
        fields.addAcceptedTotal = admission.accepted
        fields.addRejectedByError = admission.rejectedByError
        lock.unlock()

        _ = offer(ProducerDiagnostic(
            kind: .admissionSummary,
            context: fields))
    }

    /// Updates only destination context. It never calls Core or schedules
    /// work, and unsafe values are represented as null in later events.
    internal func updateDestinationContext(
        producerID: String? = nil,
        topicID: String? = nil,
        endpoint: String? = nil
    ) {
        lock.lock()
        guard Self.isEnabled(
                structuredHandler: structuredHandler,
                textHandler: textHandler,
                level: configuredLevel) else {
            lock.unlock()
            return
        }
        if let producerID { self.producerID = DiagnosticFieldPolicy.token(producerID) }
        if let topicID { self.topicID = DiagnosticFieldPolicy.token(topicID) }
        if let endpoint { endpointHost = DiagnosticFieldPolicy.endpointHost(endpoint) }
        lock.unlock()
    }

    /// Gives already-admitted work an opportunity to drain without waiting for
    /// customer I/O. The emitter owns no timer; the owner adapter stops its
    /// periodic native-stat timer separately. Boundary events offered after a
    /// producer close (for example a closed-state admission rejection) remain
    /// observable, so this method deliberately does not disable admission.
    internal func finish() {
        var scheduleDrain = false
        lock.lock()
        if !draining && (!pending.isEmpty || droppedSinceLastReport > 0) {
            draining = true
            scheduleDrain = true
        }
        lock.unlock()
        if scheduleDrain {
            queue.async { [self] in self.drain() }
        }
    }

    // MARK: - Delivery

    private static func transportRequestIDObservation(
        for diagnostic: ProducerDiagnostic
    ) -> TransportRequestIDObservation? {
        guard diagnostic.kind == .transportFinished else { return nil }
        let context = diagnostic.context
        let attemptID = context.flatMap { DiagnosticFieldPolicy.token($0.attemptID) }

        // A transport context with fields_omitted=true is authoritative even
        // when the legacy field contains the Core-normalized compatibility
        // value. Never promote that rewritten value into a correlation ID.
        let rawRequestID: String?
        if context?.fieldsOmitted == true {
            rawRequestID = context?.requestID
        } else if let contextRequestID = context?.requestID {
            rawRequestID = contextRequestID
        } else {
            rawRequestID = diagnostic.requestID
        }
        let requestID = DiagnosticFieldPolicy.requestID(rawRequestID)
        let fieldsOmitted = (context?.fieldsOmitted == true) ||
            (rawRequestID != nil && requestID == nil)
        return TransportRequestIDObservation(
            attemptID: attemptID,
            requestID: requestID,
            fieldsOmitted: fieldsOmitted)
    }

    private static func coreAttemptID(for diagnostic: ProducerDiagnostic) -> String? {
        switch diagnostic.kind {
        case .attemptFinished, .retryScheduled, .batchRetained, .batchTerminal:
            return diagnostic.context.flatMap { DiagnosticFieldPolicy.token($0.attemptID) }
        default:
            return nil
        }
    }

    /// All request-association mutation and lookup happens while `lock` is
    /// held by `offer`; this keeps callback delivery independent of the cache.
    private func rememberRequestIDAssociation(
        attemptID: String,
        requestID: String?,
        fieldsOmitted: Bool,
        now: UInt64
    ) {
        purgeExpiredRequestIDAssociations(now: now)
        requestIDAssociations.removeValue(forKey: attemptID)
        requestIDAssociationOrder.removeAll { $0 == attemptID }
        let ttl = Self.requestIDAssociationTTLNanos
        let expiresAt = now > UInt64.max - ttl ? UInt64.max : now + ttl
        requestIDAssociations[attemptID] = RequestIDAssociation(
            requestID: requestID,
            fieldsOmitted: fieldsOmitted,
            expiresAtNanoseconds: expiresAt)
        requestIDAssociationOrder.append(attemptID)
        while requestIDAssociationOrder.count > Self.maxRequestIDAssociations {
            let evicted = requestIDAssociationOrder.removeFirst()
            requestIDAssociations.removeValue(forKey: evicted)
        }
    }

    private func requestIDAssociation(
        for attemptID: String,
        now: UInt64
    ) -> RequestIDAssociation? {
        purgeExpiredRequestIDAssociations(now: now)
        return requestIDAssociations[attemptID]
    }

    private func purgeExpiredRequestIDAssociations(now: UInt64) {
        requestIDAssociationOrder.removeAll { attemptID in
            guard let association = requestIDAssociations[attemptID] else { return true }
            guard now >= association.expiresAtNanoseconds else { return false }
            requestIDAssociations.removeValue(forKey: attemptID)
            return true
        }
    }

    private static func replacing(
        _ diagnostic: ProducerDiagnostic,
        requestID: String?,
        context: ProducerDiagnosticDetails?
    ) -> ProducerDiagnostic {
        ProducerDiagnostic(
            kind: diagnostic.kind,
            reason: diagnostic.reason,
            startID: diagnostic.startID,
            endID: diagnostic.endID,
            attemptCount: diagnostic.attemptCount,
            cycleAttemptCount: diagnostic.cycleAttemptCount,
            elapsed: diagnostic.elapsed,
            retryDelay: diagnostic.retryDelay,
            logCount: diagnostic.logCount,
            rawBytes: diagnostic.rawBytes,
            compressedBytes: diagnostic.compressedBytes,
            httpCode: diagnostic.httpCode,
            transportCode: diagnostic.transportCode,
            retryable: diagnostic.retryable,
            requestID: requestID,
            errorCode: DiagnosticFieldPolicy.token(diagnostic.errorCode),
            context: context)
    }

    private static func applying(
        _ association: RequestIDAssociation,
        to diagnostic: ProducerDiagnostic
    ) -> ProducerDiagnostic {
        var context = diagnostic.context ?? ProducerDiagnosticDetails()
        context.requestID = association.requestID
        if association.fieldsOmitted { context.fieldsOmitted = true }
        return replacing(diagnostic, requestID: association.requestID, context: context)
    }

    private static func clearingUnassociatedCoreRequestID(
        _ diagnostic: ProducerDiagnostic
    ) -> ProducerDiagnostic {
        let hadRequestID = diagnostic.requestID != nil || diagnostic.context?.requestID != nil
        var context = diagnostic.context ?? ProducerDiagnosticDetails()
        context.requestID = nil
        if hadRequestID { context.fieldsOmitted = true }
        return replacing(diagnostic, requestID: nil, context: context)
    }

    private func drain() {
        while true {
            let work: QueuedEvent?
            var droppedSummary: QueuedEvent?

            lock.lock()
            if !pending.isEmpty {
                // Preserve FIFO sequence order. A dropped summary is emitted
                // only after all events admitted before it have drained.
                work = pending.removeFirst()
                lock.unlock()
            } else if droppedSinceLastReport > 0 {
                let count = droppedSinceLastReport
                droppedSinceLastReport = 0
                let sequence = nextSequence
                nextSequence = nextSequence == Int64.max ? 1 : nextSequence + 1
                let destination = (producerID, topicID, endpointHost)
                var details = ProducerDiagnosticDetails()
                details.diagnosticDroppedTotal = droppedTotal
                details.diagnosticDroppedSinceLastReport = count
                let diagnostic = ProducerDiagnostic(kind: .diagnosticsDropped, context: details)
                let timeMs = clock.wallMilliseconds()
                droppedSummary = QueuedEvent(
                    diagnostic: enrich(
                        diagnostic,
                        sequence: sequence,
                        timeMs: timeMs,
                        destination: destination),
                    sequence: sequence,
                    timeMs: timeMs,
                    isDropSummary: true)
                work = nil
                lock.unlock()
            } else {
                draining = false
                lock.unlock()
                return
            }

            if let work { deliver(work) }
            if let droppedSummary { deliver(droppedSummary) }
        }
    }

    private func deliver(_ event: QueuedEvent) {
        // The event was sanitized and enriched before entering the bounded
        // queue. Structured delivery is deliberately first on the same queue.
        structuredHandler?(event.diagnostic)

        guard let textHandler,
              configuredLevel != .off else { return }
        let level = DiagnosticFormatter.eventLevel(for: event.diagnostic)
        // A text threshold is an intentional filter, not an emitter drop.
        // Only a formatter failure contributes to diagnosticsDropped.
        guard level.rawValue >= configuredLevel.rawValue,
              level != .off else { return }
        guard let message = DiagnosticFormatter.format(
            event.diagnostic,
            level: level,
            sequence: event.sequence,
            timeMs: event.timeMs,
            source: source,
            context: event.diagnostic.context) else {
            if !event.isDropSummary { recordFormatterDrop() }
            return
        }
        textHandler(level, message)
    }

    private func recordFormatterDrop() {
        lock.lock()
        droppedTotal += 1
        droppedSinceLastReport += 1
        lock.unlock()
    }

    private func enrich(
        _ diagnostic: ProducerDiagnostic,
        sequence: Int64,
        timeMs: Int64,
        destination: (String?, String?, String?)
    ) -> ProducerDiagnostic {
        let transportObservation = Self.transportRequestIDObservation(for: diagnostic)
        let transportDiagnostic: ProducerDiagnostic
        if let transportObservation {
            var transportContext = diagnostic.context ?? ProducerDiagnosticDetails()
            transportContext.requestID = transportObservation.requestID
            if transportObservation.fieldsOmitted { transportContext.fieldsOmitted = true }
            transportDiagnostic = Self.replacing(
                diagnostic,
                requestID: transportObservation.requestID,
                context: transportContext)
        } else {
            transportDiagnostic = diagnostic
        }
        var context = DiagnosticFormatter.sanitizeContext(
            transportDiagnostic.context ?? ProducerDiagnosticDetails())
        var occurrence = ProducerDiagnosticDetails()
        occurrence.schemaVersion = 1
        occurrence.event = transportDiagnostic.kind.eventName
        occurrence.level = DiagnosticFormatter.eventLevel(for: transportDiagnostic)
        occurrence.source = context.source ?? source
        occurrence.timeMs = timeMs
        occurrence.sequence = sequence
        occurrence.sdkVersion = sdkVersion
        occurrence.producerInstanceID = producerInstanceID
        occurrence.producerID = destination.0
        occurrence.topicID = destination.1
        occurrence.endpointHost = destination.2
        context = DiagnosticFormatter.sanitizeContext(context.merging(occurrence))

        // The existing legacy fields are also copied through the same string
        // policy before structured delivery. No raw server/error text crosses
        // the public callback boundary.
        let safeRequestID = DiagnosticFieldPolicy.requestID(transportDiagnostic.requestID)
        return Self.replacing(
            transportDiagnostic,
            requestID: safeRequestID,
            context: context)
    }

    private static func isEnabled(
        structuredHandler: (@Sendable (ProducerDiagnostic) -> Void)?,
        textHandler: (@Sendable (ProducerDiagnosticLogLevel, String) -> Void)?,
        level: ProducerDiagnosticLogLevel
    ) -> Bool {
        structuredHandler != nil || (textHandler != nil && level != .off)
    }

    private static func safeSource(_ value: String) -> String? {
        switch value {
        case "facade", "producer", "core", "transport", "lifecycle": return value
        default: return nil
        }
    }
}
