//
//  SendResult.swift
//  VolcengineTLSProducer
//
//  Worker A — Swift public value model.
//

import Foundation

/// Terminal result of one batch. Exactly one `SendResult` is delivered per
/// accepted batch via the `onSendResult` handler registered at `open`.
///
/// This is the stable minimal field set (ledger O7/O9): no attemptCount,
/// dropReason, or checkpointDurable — the Core cannot provide them stably
/// yet.
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
