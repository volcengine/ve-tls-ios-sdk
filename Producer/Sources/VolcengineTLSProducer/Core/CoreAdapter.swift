//
//  CoreAdapter.swift
//  VolcengineTLSProducer/Core
//
//  Internal boundary between the Swift API and the Core engine.
//

import Foundation

/// `CoreAdapter` is the boundary between the Swift `Producer` facade and the
/// underlying Core engine. It is package-internal; tests access it through
/// `@testable import` and it is not part of the consumer API or ABI.
///
/// Conformance rules:
/// - All methods must be safe to call from any thread; conformers serialize
///   their internal state themselves.
/// - `onSendResult` closures MUST be delivered on the
///   `configuration.callbackQueue` passed to `open(configuration:credentials:)`,
///   and MUST NOT be invoked while holding any lock that `add`, `close`, or
///   `update*` may acquire (no deadlock, no reentrancy).
/// - A batch produces at most one terminal `SendResult` for one live
///   producer. A durable retry-delayed batch may instead be persisted during
///   local close and recovered by a later producer, so the old handler is not
///   promised a synthetic terminal result.
/// - `close(timeout:)` bounds local shutdown work (worker stop, local
///   persistence flush) and throws if the Core cannot complete that work; it
///   must not promise remote delivery of accepted logs.
protocol CoreAdapter: AnyObject {

    /// Terminal-result handler for batches. Set by the `Producer` before
    /// `open` is called; must not be replaced at runtime.
    var onSendResult: (@Sendable (SendResult) -> Void)? { get set }

    /// Opens the adapter with the frozen configuration and the first
    /// credentials group. Throws on configuration/state failures.
    func open(configuration: ProducerConfiguration, credentials: Credentials) throws

    /// Admits one pre-validated, pre-snapshotted event. `.immediate` seals
    /// the current batch and wakes the sender; admission never waits for the
    /// network or an ACK.
    func add(_ event: PreparedLogEvent, mode: AddMode) throws

    /// Atomically replaces the whole credentials group.
    func updateCredentials(_ credentials: Credentials) throws

    /// Atomically replaces the whole destination (current-target semantics:
    /// previously accepted logs are later sent to the new destination).
    func updateDestination(_ destination: Destination) throws

    /// Bounded local shutdown. Idempotent from the `Producer`'s perspective;
    /// conformers may assume a single in-flight call.
    func close(timeout: TimeInterval) async throws
}
