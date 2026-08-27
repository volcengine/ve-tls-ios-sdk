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
        for (key, value) in contents {
            // Keys must be non-empty UTF-8 strings (Beta design §5.3).
            if key.isEmpty {
                violations.append("<empty-key>: key must be a non-empty UTF-8 string")
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
