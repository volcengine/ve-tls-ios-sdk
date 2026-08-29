//
//  LogEvent.swift
//  VolcengineTLSProducer
//
//  Worker A — Swift public value model.
//

import Foundation

/// A single log entry: a timestamp, an optional hash key, and a set of typed
/// content fields.
///
/// `LogEvent` is a value type. `Producer.add` takes it by value, so the event
/// is snapshotted at the admission call boundary; later mutation of the
/// original value never affects the admitted copy.
///
/// - Note: When `timestamp` is omitted, it is captured at `LogEvent`
///   initialization. Create the event at (or immediately before) the
///   `add` call so the default timestamp reflects the admission moment.
public struct LogEvent: Equatable, Sendable {

    /// Event time. Unix epoch milliseconds are derived from this date by the
    /// transport layer.
    public var timestamp: Date {
        didSet { cachedAdmissionSnapshot = nil }
    }

    /// Optional per-log hash key. When present, it must be exactly 32
    /// lowercase hexadecimal characters (`[0-9a-f]{32}`). When `nil`, the
    /// producer/Core default (round-robin / configured default hash key)
    /// applies.
    public var hashKey: String? {
        didSet { cachedAdmissionSnapshot = nil }
    }

    /// Content fields. Keys must be non-empty strings; values follow the
    /// `LogValue` encoding rules.
    public var contents: [String: LogValue] {
        didSet { cachedAdmissionSnapshot = nil }
    }

    /// Valid non-empty events are encoded once when built. Public fields stay
    /// mutable; every mutation invalidates this value before a later add can
    /// observe it, preserving LogEvent value semantics.
    private var cachedAdmissionSnapshot: PreparedLogEvent?

    public init(timestamp: Date = Date(),
                hashKey: String? = nil,
                contents: [String: LogValue] = [:]) {
        self.timestamp = timestamp
        self.hashKey = hashKey
        self.contents = contents
        self.cachedAdmissionSnapshot = nil
        self.cachedAdmissionSnapshot = try? prepare(requireNonEmptyContents: true)
    }

    public static func == (lhs: LogEvent, rhs: LogEvent) -> Bool {
        lhs.timestamp == rhs.timestamp &&
            lhs.hashKey == rhs.hashKey &&
            lhs.contents == rhs.contents
    }

    /// Validates every field of this event. If any field is invalid, the whole
    /// event is rejected with `ProducerError.invalidLog` listing the violating
    /// field paths; partial admission never happens.
    internal func validate() throws {
        if cachedAdmissionSnapshot != nil {
            return
        }
        _ = try prepare(requireNonEmptyContents: false)
    }

    /// Builds the immutable snapshot consumed by the Core boundary. Validation,
    /// value encoding, timestamp conversion, and raw-byte accounting deliberately
    /// happen in one traversal so `Producer.add` never repeats this work.
    internal func prepareForAdmission() throws -> PreparedLogEvent {
        if let cachedAdmissionSnapshot {
            return cachedAdmissionSnapshot
        }
        return try prepare(requireNonEmptyContents: true)
    }

    /// Internal observability for contract tests; not part of the public API.
    internal var hasCachedAdmissionSnapshot: Bool {
        cachedAdmissionSnapshot != nil
    }

    private func prepare(requireNonEmptyContents: Bool) throws -> PreparedLogEvent {
        var violations: [String] = []
        let timestampMilliseconds = timestamp.timeIntervalSince1970 * 1_000
        var encodedTimestampMilliseconds: Int64 = 0
        if !timestampMilliseconds.isFinite ||
            timestampMilliseconds < Double(Int64.min) ||
            // Double(Int64.max) rounds up to 2^63, which Int64 cannot hold.
            timestampMilliseconds >= Double(Int64.max) {
            violations.append("timestamp: must fit in finite Unix epoch milliseconds")
        } else {
            encodedTimestampMilliseconds = Int64(timestampMilliseconds)
        }
        if let hashKey {
            let bytes = hashKey.utf8
            let isLowercaseHex = bytes.count == 32 &&
                bytes.allSatisfy { byte in
                    (byte >= 0x30 && byte <= 0x39) ||
                        (byte >= 0x61 && byte <= 0x66)
                }
            if !isLowercaseHex {
                violations.append(
                    "hashKey: must match lowercase hexadecimal [0-9a-f]{32}")
            }
        }
        var encodedFields: [String] = []
        encodedFields.reserveCapacity(contents.count * 2)
        var rawBytes = 0
        for (key, value) in contents {
            // Keys must be non-empty UTF-8 strings (Beta design §5.3).
            if key.isEmpty {
                violations.append("<empty-key>: key must be a non-empty UTF-8 string")
                continue
            }
            if key.utf8.contains(0) {
                violations.append("\(key): key must not contain embedded NUL characters")
                continue
            }
            do {
                let encoded = try value.encodedString()
                encodedFields.append(key)
                encodedFields.append(encoded)
                rawBytes = Self.saturatingAdd(rawBytes, key.utf8.count)
                rawBytes = Self.saturatingAdd(rawBytes, encoded.utf8.count)
            } catch {
                violations.append("\(key): \(error)")
            }
        }
        if !violations.isEmpty {
            throw ProducerError.invalidLog(violations)
        }
        if requireNonEmptyContents && contents.isEmpty {
            throw ProducerError.invalidLog([
                "contents: must contain at least one field"
            ])
        }
        return PreparedLogEvent(
            timestampMilliseconds: encodedTimestampMilliseconds,
            hashKey: hashKey,
            encodedFields: encodedFields,
            rawBytes: rawBytes)
    }

    /// Best-effort encoded size in bytes (key UTF-8 + encoded value UTF-8).
    /// Used for admission checks and `SendResult.rawBytes` bookkeeping.
    /// Invalid values contribute 0 bytes; callers must validate separately.
    internal func estimatedRawBytes() -> Int {
        var total = 0
        for (key, value) in contents {
            total = Self.saturatingAdd(total, key.utf8.count)
            if let encoded = try? value.encodedString() {
                total = Self.saturatingAdd(total, encoded.utf8.count)
            }
        }
        return total
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

/// Package-internal, immutable admission snapshot. Fields are flattened once
/// at the Swift boundary so the ObjC bridge never has to enumerate and look up
/// values in a lazily bridged Swift dictionary on every admission.
internal struct PreparedLogEvent: Equatable, Sendable {
    let timestampMilliseconds: Int64
    let hashKey: String?
    /// Alternating key/value strings: `[key0, value0, key1, value1, ...]`.
    let encodedFields: [String]
    let rawBytes: Int

    var encodedKeys: [String] {
        stride(from: 0, to: encodedFields.count, by: 2).map { encodedFields[$0] }
    }

    var encodedValues: [String] {
        stride(from: 1, to: encodedFields.count, by: 2).map { encodedFields[$0] }
    }

    /// Test/debug convenience. Production RealCore admission consumes the
    /// interleaved field array directly and does not materialize this dictionary.
    var encodedContents: [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(encodedFields.count / 2)
        for index in stride(from: 0, to: encodedFields.count, by: 2) {
            result[encodedFields[index]] = encodedFields[index + 1]
        }
        return result
    }
}
