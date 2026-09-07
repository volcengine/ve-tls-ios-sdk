//
//  ProducerMetadata.swift
//  VolcengineTLSProducer
//
//  Producer metadata.
//

import Foundation

/// Producer-level (log-group) metadata: `source`, `fileName`, and `tags`.
///
/// Metadata applies to the whole producer. It is attached to every log group;
/// individual events cannot override it.
public struct ProducerMetadata: Equatable, Sendable {

    /// Log source marker. Defaults to `"iOS"` on iOS and `"macOS"` on
    /// native macOS. An empty string omits the source marker.
    public var source: String

    /// Optional file name marker for the log group. Accepts nil or an empty string.
    public var fileName: String?

    /// Static tags attached to every log group produced by this producer.
    /// Accepts an empty dictionary and empty keys or values.
    public var tags: [String: String]

#if os(macOS)
    public init(source: String = "macOS",
                fileName: String? = nil,
                tags: [String: String] = [:]) {
        self.source = source
        self.fileName = fileName
        self.tags = tags
    }
#else
    public init(source: String = "iOS",
                fileName: String? = nil,
                tags: [String: String] = [:]) {
        self.source = source
        self.fileName = fileName
        self.tags = tags
    }
#endif

    internal func validate() throws {
        guard !source.contains("\0"), fileName?.contains("\0") != true else {
            throw ProducerError.configuration(
                "metadata source/fileName must not contain embedded NUL characters")
        }
        guard tags.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw ProducerError.configuration(
                "metadata tags must not contain embedded NUL characters")
        }
    }
}
