//
//  CoreAdapter.swift
//  VolcengineTLSProducer/Core
//
//  Worker A — provisional seam between the Swift facade and the Core engine.
//

import Foundation

/// PROVISIONAL — internal seam, not a public API contract; may change/remove
/// without notice. 真实 Core 合同确认前不得冻结。
///
/// `CoreAdapter` is the boundary between the Swift `Producer` facade and the
/// underlying Core engine (C Core via Bridge, or a bundled in-memory
/// implementation). It is declared `public` only so that test-support
/// targets (e.g. `ProducerTestSupport.FakeCoreAdapter`) can conform to it;
/// it is **not** a stable public API and is not covered by SemVer promises.
///
/// Conformance rules:
/// - All methods must be safe to call from any thread; conformers serialize
///   their internal state themselves.
/// - `onSendResult` closures MUST be delivered on the
///   `configuration.callbackQueue` passed to `open(configuration:credentials:)`,
///   and MUST NOT be invoked while holding any lock that `add`, `close`, or
///   `update*` may acquire (no deadlock, no reentrancy).
/// - Each accepted batch produces exactly one terminal `SendResult`.
/// - `close(timeout:)` is non-throwing and bounds local shutdown work
///   (worker stop, local persistence flush); it must not promise remote
///   delivery of accepted logs.
public protocol CoreAdapter: AnyObject {

    /// Terminal-result handler for batches. Set by the `Producer` before
    /// `open` is called; must not be replaced at runtime.
    var onSendResult: (@Sendable (SendResult) -> Void)? { get set }

    /// Opens the adapter with the frozen configuration and the first
    /// credentials group. Throws on configuration/state failures.
    func open(configuration: ProducerConfiguration, credentials: Credentials) throws

    /// Admits one pre-validated, pre-snapshotted event. `.immediate` seals
    /// the current batch and wakes the sender; admission never waits for the
    /// network or an ACK.
    func add(_ event: LogEvent, mode: AddMode) throws

    /// Atomically replaces the whole credentials group.
    func updateCredentials(_ credentials: Credentials) throws

    /// Atomically replaces the whole destination (current-target semantics:
    /// previously accepted logs are later sent to the new destination).
    func updateDestination(_ destination: Destination) throws

    /// Bounded local shutdown. Idempotent from the `Producer`'s perspective;
    /// conformers may assume a single in-flight call.
    func close(timeout: TimeInterval) async
}
