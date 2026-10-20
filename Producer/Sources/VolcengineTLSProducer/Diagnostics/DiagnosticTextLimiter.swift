import Foundation

/// Applies the bounded text-only diagnostic budget after structured delivery.
///
/// Instances are owned by one `DiagnosticEmitter` and are called only from
/// that emitter's private serial drain queue. The class is nevertheless marked
/// sendable because the emitter itself is sendable and owns the queue seam.
internal final class DiagnosticTextLimiter: @unchecked Sendable {
    internal static let defaultWindowNanoseconds: UInt64 = 60_000_000_000
    internal static let defaultMessageLimit = 30
    internal static let defaultByteLimit = 32 * 1_024
    internal static let defaultFingerprintLimit = 128

    private enum Bucket: Equatable {
        case normal
        case fault
    }

    private struct Emission {
        let time: UInt64
        let bytes: Int
    }

    private struct BucketState {
        var emissions: [Emission] = []
    }

    private struct FaultFingerprint: Hashable {
        let kind: Int
        let reason: Int
        let errorCode: String?
        let httpCode: Int?
        let transportCode: Int?
        let admissionStage: String?
        let disposition: String?
    }

    internal enum Output {
        case emitted(String)
        case formatterFailed
    }

    private let messageLimit: Int
    private let byteLimit: Int
    private let windowNanoseconds: UInt64
    private let fingerprintLimit: Int

    private var normal = BucketState()
    private var fault = BucketState()
    private var fingerprints: [FaultFingerprint: UInt64] = [:]
    private var suppressedTotal: Int64 = 0
    private var suppressedSinceReport: Int64 = 0

    internal init(
        messageLimit: Int = DiagnosticTextLimiter.defaultMessageLimit,
        byteLimit: Int = DiagnosticTextLimiter.defaultByteLimit,
        windowNanoseconds: UInt64 = DiagnosticTextLimiter.defaultWindowNanoseconds,
        fingerprintLimit: Int = DiagnosticTextLimiter.defaultFingerprintLimit
    ) {
        self.messageLimit = max(1, messageLimit)
        self.byteLimit = max(1, byteLimit)
        self.windowNanoseconds = max(1, windowNanoseconds)
        self.fingerprintLimit = max(1, fingerprintLimit)
    }

    /// Returns an emitted text message, or nil when the event is
    /// duplicate/suppressed/off. `render` is called only when the event can
    /// potentially be emitted and receives the pending text-only counters.
    /// A formatter failure is explicit so the emitter can account for it
    /// without consuming or losing the pending suppression counters.
    internal func output(
        level: ProducerDiagnosticLogLevel,
        diagnostic: ProducerDiagnostic,
        now: UInt64,
        render: (_ total: Int64?, _ sinceReport: Int64?) -> String?
    ) -> Output? {
        guard let bucket = Self.bucket(for: level) else { return nil }
        purgeExpiredEmissions(in: bucket, now: now)
        purgeExpiredFingerprints(now: now)

        let fingerprint: FaultFingerprint?
        if bucket == .fault {
            fingerprint = Self.fingerprint(for: diagnostic)
            if let fingerprint,
               fingerprints[fingerprint] != nil {
                recordSuppression()
                return nil
            }
        } else {
            fingerprint = nil
        }

        // A full line quota can be decided without constructing JSON. The
        // byte quota is checked after rendering because UTF-8 size includes
        // the actual message and its trailing newline.
        guard hasMessageCapacity(in: bucket) else {
            recordSuppression()
            return nil
        }

        let pendingTotal = suppressedTotal > 0 ? suppressedTotal : nil
        let pendingSinceReport = suppressedSinceReport > 0 ? suppressedSinceReport : nil
        guard let message = render(pendingTotal, pendingSinceReport) else {
            return .formatterFailed
        }
        let bytes = message.utf8.count + 1 // The text sink appends one newline.
        guard hasCapacity(in: bucket, bytes: bytes) else {
            recordSuppression()
            return nil
        }

        append(Emission(time: now, bytes: bytes), to: bucket)
        if let fingerprint { remember(fingerprint, now: now) }
        suppressedSinceReport = 0
        return .emitted(message)
    }

    private static func bucket(for level: ProducerDiagnosticLogLevel) -> Bucket? {
        switch level {
        case .debug, .info:
            return .normal
        case .warning, .error:
            return .fault
        case .off:
            return nil
        }
    }

    private static func fingerprint(for diagnostic: ProducerDiagnostic) -> FaultFingerprint {
        let context = diagnostic.context
        return FaultFingerprint(
            kind: diagnostic.kind.rawValue,
            reason: diagnostic.reason.rawValue,
            errorCode: DiagnosticFieldPolicy.token(context?.errorCode ?? diagnostic.errorCode),
            httpCode: context?.httpCode ?? diagnostic.httpCode,
            transportCode: context?.transportCode ?? diagnostic.transportCode,
            admissionStage: DiagnosticFieldPolicy.admissionStage(context?.admissionStage),
            disposition: DiagnosticFieldPolicy.token(context?.disposition))
    }

    private func purgeExpiredEmissions(in bucket: Bucket, now: UInt64) {
        switch bucket {
        case .normal:
            normal.emissions.removeAll { isExpired($0.time, now: now) }
        case .fault:
            fault.emissions.removeAll { isExpired($0.time, now: now) }
        }
    }

    private func purgeExpiredFingerprints(now: UInt64) {
        fingerprints = fingerprints.filter { !isExpired($0.value, now: now) }
    }

    private func isExpired(_ time: UInt64, now: UInt64) -> Bool {
        now >= time && now - time >= windowNanoseconds
    }

    private func hasMessageCapacity(in bucket: Bucket) -> Bool {
        emissions(in: bucket).count < messageLimit && usedBytes(in: bucket) < byteLimit
    }

    private func hasCapacity(in bucket: Bucket, bytes: Int) -> Bool {
        let emissions = emissions(in: bucket)
        let usedBytes = usedBytes(in: bucket)
        return emissions.count < messageLimit &&
            bytes <= byteLimit &&
            usedBytes <= byteLimit - bytes
    }

    private func emissions(in bucket: Bucket) -> [Emission] {
        switch bucket {
        case .normal:
            return normal.emissions
        case .fault:
            return fault.emissions
        }
    }

    private func usedBytes(in bucket: Bucket) -> Int {
        emissions(in: bucket).reduce(into: 0) { result, emission in
            result = min(byteLimit, result + min(byteLimit, emission.bytes))
        }
    }

    private func append(_ emission: Emission, to bucket: Bucket) {
        switch bucket {
        case .normal: normal.emissions.append(emission)
        case .fault: fault.emissions.append(emission)
        }
    }

    private func remember(_ fingerprint: FaultFingerprint, now: UInt64) {
        if fingerprints.count >= fingerprintLimit {
            var oldest: (fingerprint: FaultFingerprint, time: UInt64)?
            for pair in fingerprints {
                if oldest == nil || pair.value < oldest!.time {
                    oldest = (pair.key, pair.value)
                }
            }
            if let oldest { fingerprints.removeValue(forKey: oldest.fingerprint) }
        }
        fingerprints[fingerprint] = now
    }

    private func recordSuppression() {
        if suppressedTotal < Int64.max { suppressedTotal += 1 }
        if suppressedSinceReport < Int64.max { suppressedSinceReport += 1 }
    }
}
