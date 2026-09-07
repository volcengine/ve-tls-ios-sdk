//
//  ProducerError.swift
//  VolcengineTLSProducer
//
//  Producer error model.
//

import Foundation

/// Stable error contract for the producer.
///
/// `errorCode` strings are part of the contract and must not change.
/// Descriptions never contain credentials, `Authorization` headers, or raw
/// log bodies.
public enum ProducerError: Error, Equatable, Sendable {

    /// Invalid configuration (human-readable reason).
    case configuration(String)

    /// One or more log fields are invalid; the associated value lists the
    /// violating field paths. The whole event is rejected — no partial
    /// admission.
    case invalidLog([String])

    /// Operation not allowed in the current producer state (e.g. `add`
    /// during `open`, or on a failed-to-open producer).
    case invalidState

    /// In-memory admission queue is full (fail-fast policy).
    case queueFull

    /// Buffer capacity is exhausted.
    case bufferFull

    /// A single log exceeds the configured batch byte limit.
    case singleLogTooLarge

    /// Persistence/WAL failure (human-readable reason).
    case persistence(String)

    /// Transport-level failure (DNS/TLS/connect/timeout/cancelled).
    case transport(String)

    /// Service-side failure with HTTP status code, message, and optional
    /// request ID.
    case service(code: Int, message: String, requestID: String?)

    /// Authentication/authorization failure (401/403 family).
    case auth

    /// Quota/rate-limit failure.
    case quota

    /// A bounded wait exceeded its deadline.
    case timeout

    /// The operation was cancelled.
    case cancelled

    /// The producer is closed (or closing). New `add`/`update*` calls are
    /// rejected.
    case closed

    /// Internal invariant failure (human-readable reason).
    /// Backticked because `internal` is a Swift keyword.
    case `internal`(String)

    /// Stable error code string. Never change these values.
    public var errorCode: String {
        switch self {
        case .configuration: return "configuration"
        case .invalidLog: return "invalidLog"
        case .invalidState: return "invalidState"
        case .queueFull: return "queueFull"
        case .bufferFull: return "bufferFull"
        case .singleLogTooLarge: return "singleLogTooLarge"
        case .persistence: return "persistence"
        case .transport: return "transport"
        case .service: return "service"
        case .auth: return "auth"
        case .quota: return "quota"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .closed: return "closed"
        case .`internal`: return "internal"
        }
    }
}

extension ProducerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configuration(let reason):
            return "configuration: \(reason)"
        case .invalidLog(let paths):
            return "invalidLog: \(paths.joined(separator: ", "))"
        case .invalidState:
            return "invalidState"
        case .queueFull:
            return "queueFull"
        case .bufferFull:
            return "bufferFull"
        case .singleLogTooLarge:
            return "singleLogTooLarge"
        case .persistence(let reason):
            return "persistence: \(reason)"
        case .transport(let reason):
            return "transport: \(reason)"
        case .service(let code, let message, let requestID):
            if let requestID = requestID {
                return "service(\(code)): \(message) (requestID: \(requestID))"
            }
            return "service(\(code)): \(message)"
        case .auth:
            return "auth"
        case .quota:
            return "quota"
        case .timeout:
            return "timeout"
        case .cancelled:
            return "cancelled"
        case .closed:
            return "closed"
        case .`internal`(let reason):
            return "internal: \(reason)"
        }
    }
}
