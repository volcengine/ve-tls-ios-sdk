//
//  ProducerMetadata.swift
//  VolcengineTLSProducer
//
//  Worker A — Swift public value model.
//

import Foundation

/// Producer-level (log-group) metadata: `source`, `fileName`, and `tags`.
///
/// Metadata applies to the whole producer; Beta has no per-log tags and no
/// override/merge precedence. Replaced as a whole group.
public struct ProducerMetadata: Equatable, Sendable {

    /// Log source marker. Default in `ProducerConfiguration` is `"iOS"`.
    public var source: String

    /// Optional file name marker for the log group.
    public var fileName: String?

    /// Static tags attached to every log group produced by this producer.
    public var tags: [String: String]

    public init(source: String = "iOS",
                fileName: String? = nil,
                tags: [String: String] = [:]) {
        self.source = source
        self.fileName = fileName
        self.tags = tags
    }

    internal func validate() throws {
        guard !source.isEmpty else {
            throw ProducerError.configuration("metadata.source must not be empty")
        }
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
