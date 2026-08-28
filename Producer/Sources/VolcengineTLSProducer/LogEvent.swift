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
    public var timestamp: Date

    /// Optional per-log hash key. When `nil`, the producer/Core default
    /// (round-robin / configured default hash key) applies.
    public var hashKey: String?

    /// Content fields. Keys must be non-empty strings; values follow the
    /// `LogValue` encoding rules.
    public var contents: [String: LogValue]

    public init(timestamp: Date = Date(),
                hashKey: String? = nil,
                contents: [String: LogValue] = [:]) {
        self.timestamp = timestamp
        self.hashKey = hashKey
        self.contents = contents
    }

    /// Validates every field of this event. If any field is invalid, the whole
    /// event is rejected with `ProducerError.invalidLog` listing the violating
    /// field paths; partial admission never happens.
    internal func validate() throws {
        var violations: [String] = []
        let timestampMilliseconds = timestamp.timeIntervalSince1970 * 1_000
        if !timestampMilliseconds.isFinite ||
            timestampMilliseconds < Double(Int64.min) ||
            // Double(Int64.max) rounds up to 2^63, which Int64 cannot hold.
            timestampMilliseconds >= Double(Int64.max) {
            violations.append("timestamp: must fit in finite Unix epoch milliseconds")
        }
        if let hashKey {
            if hashKey.contains("\0") {
                violations.append("hashKey: must not contain embedded NUL characters")
            } else {
                let bytes = hashKey.utf8
                let isLowercaseHex = !bytes.isEmpty &&
                    bytes.count <= 32 &&
                    bytes.allSatisfy { byte in
                        (byte >= 0x30 && byte <= 0x39) ||
                            (byte >= 0x61 && byte <= 0x66)
                    }
                if !isLowercaseHex {
                    violations.append(
                        "hashKey: must match non-empty lowercase hexadecimal [0-9a-f]{1,32}")
                }
            }
        }
        for (key, value) in contents {
            // Keys must be non-empty UTF-8 strings (Beta design §5.3).
            if key.isEmpty {
                violations.append("<empty-key>: key must be a non-empty UTF-8 string")
                continue
            }
            if key.contains("\0") {
                violations.append("\(key): key must not contain embedded NUL characters")
                continue
            }
            do {
                try value.validate()
            } catch {
                violations.append("\(key): \(error)")
            }
        }
        if !violations.isEmpty {
            throw ProducerError.invalidLog(violations)
        }
    }

    /// Best-effort encoded size in bytes (key UTF-8 + encoded value UTF-8).
    /// Used for admission checks and `SendResult.rawBytes` bookkeeping.
    /// Invalid values contribute 0 bytes; callers must validate separately.
    internal func estimatedRawBytes() -> Int {
        var total = 0
        for (key, value) in contents {
            total += key.utf8.count
            if let encoded = try? value.encodedString() {
                total += encoded.utf8.count
            }
        }
        return total
    }
}
