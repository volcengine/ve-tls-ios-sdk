//
//  SendResult.swift
//  VolcengineTLSProducer
//
//  Producer send result.
//

import Foundation

/// Terminal result of one batch. At most one `SendResult` is delivered per
/// sealed batch to the handler of the live `Producer` instance that owns it.
/// A durable batch may instead remain in WAL after local `close` and be
/// recovered by a later instance, so the earlier handler is not guaranteed a
/// terminal result after that instance stops.
///
/// The result intentionally contains only fields that are available for every
/// terminal outcome.
public struct SendResult: Equatable, Sendable {

    public enum Status: Equatable, Sendable {
        case success
        case failure
    }

    public let status: Status

    /// Uncompressed batch size in bytes.
    public let rawBytes: Int

    /// Compressed batch size in bytes.
    public let compressedBytes: Int

    /// Service request ID when available.
    public let requestID: String?

    /// Failure cause. `nil` when `status == .success`.
    public let error: ProducerError?

    public init(status: Status,
                rawBytes: Int,
                compressedBytes: Int,
                requestID: String?,
                error: ProducerError?) {
        self.status = status
        self.rawBytes = rawBytes
        self.compressedBytes = compressedBytes
        self.requestID = requestID
        self.error = error
    }
}
