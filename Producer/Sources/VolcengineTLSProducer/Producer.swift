//
//  Producer.swift
//  VolcengineTLSProducer
//
//  Public lifecycle facade.
//

import Foundation

/// Entry point of the Volcengine TLS Producer SDK.
///
/// P0 public API (frozen): `open`, `add(mode:)`, `updateCredentials`,
/// `updateDestination`, `close`. There is no remote-terminal `flush`, no
/// resume/delivery-state API, and no rich metrics in P0.
///
/// Threading:
/// - `add` and `update*` are synchronous and non-blocking on the network;
///   they perform bounded local work only.
/// - `open` and `close` are async. Each async call resumes exactly once.
///   Swift `Task` cancellation does not tear down the adapter and never
///   loses admitted logs; it simply does not interrupt the bounded local
///   work.
/// - `onSendResult` handlers are delivered on
///   `configuration.callbackQueue` (a serial utility queue by default).
public final class Producer: @unchecked Sendable {

    // MARK: - Lifecycle

    private enum State {
        case initialized
        case opening
        case ready
        case closing
        case closed
        case failed
    }

    private let lock = NSLock()
    private var state: State = .initialized
    private var closeResult: Result<Void, Error>?
    private var activeCloseAttempt: CloseAttempt?

    private let adapter: CoreAdapter
    private let configuration: ProducerConfiguration
    private var snapshot: ConfigurationSnapshot
    private var openCredentials: Credentials?
    private let userOnSendResult: (@Sendable (SendResult) -> Void)?
    private let requireDestinationOnOpen: Bool

    private enum CloseAction {
        case completed(Result<Void, Error>)
        case wait(CloseAttempt)
        case start(CloseAttempt)
        case invalidState
    }

    /// A per-attempt rendezvous. Keeping the result on the attempt object
    /// means a waiter that races with a failed close still receives that
    /// attempt's result even if a later close retry has already started.
    private final class CloseAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        private var waiters: [CheckedContinuation<Void, Error>] = []

        func wait() async throws {
            try await withCheckedThrowingContinuation { continuation in
                let finished: Result<Void, Error>? = withLock {
                    if let result {
                        return result
                    }
                    waiters.append(continuation)
                    return nil
                }
                if let finished {
                    continuation.resume(with: finished)
                }
            }
        }

        func finish(_ result: Result<Void, Error>) {
            let pending: [CheckedContinuation<Void, Error>] = withLock {
                guard self.result == nil else { return [] }
                self.result = result
                let pending = self.waiters
                self.waiters = []
                return pending
            }
            for waiter in pending {
                waiter.resume(with: result)
            }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    /// Internal injection point for deterministic facade tests. Not part of
    /// the public API; public open always constructs `RealCoreAdapter`.
    internal init(adapter: CoreAdapter,
                  configuration: ProducerConfiguration,
                  credentials: Credentials,
                  onSendResult: (@Sendable (SendResult) -> Void)?,
                  requireDestination: Bool = false) {
        self.adapter = adapter
        self.configuration = configuration
        self.snapshot = ConfigurationSnapshot(configuration)
        self.openCredentials = credentials
        self.userOnSendResult = onSendResult
        self.requireDestinationOnOpen = requireDestination

        // The adapter guarantees delivery on configuration.callbackQueue and
        // never calls back under a lock (see CoreAdapter contract). The
        // Producer therefore forwards to the user handler directly.
        adapter.onSendResult = { [weak self] result in
            guard let self = self else { return }
            let handler = self.withStateLock { self.userOnSendResult }
            handler?(result)
        }
    }

    /// Opens a producer with the real C Core adapter (ve-tls-c-sdk v0.3.1).
    ///
    /// Public open requires a valid HTTPS destination. The adapter is built
    /// on a utility executor because construction can create persistent
    /// storage and recover a WAL.
    public static func open(
        configuration: ProducerConfiguration,
        credentials: Credentials,
        onSendResult: (@Sendable (SendResult) -> Void)? = nil
    ) async throws -> Producer {
        let validatedConfiguration = try configuration.validatedForOpen(
            requireDestination: true)
        try credentials.validate()

        let adapter = try await makeRealCoreAdapter(
            configuration: validatedConfiguration,
            credentials: credentials)
        let producer = Producer(
            adapter: adapter,
            configuration: validatedConfiguration,
            credentials: credentials,
            onSendResult: onSendResult,
            requireDestination: true)
        try await producer.performOpen()
        return producer
    }

    /// Internal injection variant of `open` for tests / future adapters.
    internal static func open(
        adapter: CoreAdapter,
        configuration: ProducerConfiguration,
        credentials: Credentials,
        onSendResult: (@Sendable (SendResult) -> Void)? = nil
    ) async throws -> Producer {
        let validatedConfiguration = try configuration.validatedForOpen(
            requireDestination: false)
        try credentials.validate()
        let producer = Producer(
            adapter: adapter,
            configuration: validatedConfiguration,
            credentials: credentials,
            onSendResult: onSendResult,
            requireDestination: false)
        try await producer.performOpen()
        return producer
    }

    private final class AdapterConstructionInput: @unchecked Sendable {
        let configuration: ProducerConfiguration
        let credentials: Credentials

        init(configuration: ProducerConfiguration, credentials: Credentials) {
            self.configuration = configuration
            self.credentials = credentials
        }
    }

    private final class AdapterBox: @unchecked Sendable {
        let adapter: CoreAdapter

        init(adapter: CoreAdapter) {
            self.adapter = adapter
        }
    }

    /// Constructs the real adapter after the first suspension point. The
    /// input/result boxes are explicitly unchecked Sendable because the
    /// configuration contains Foundation reference types; ownership is
    /// transferred exactly once to the newly created Producer.
    private static func makeRealCoreAdapter(
        configuration: ProducerConfiguration,
        credentials: Credentials
    ) async throws -> CoreAdapter {
        let input = AdapterConstructionInput(
            configuration: configuration,
            credentials: credentials)
        let box = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let adapter = try RealCoreAdapter(
                        configuration: input.configuration,
                        credentials: input.credentials)
                    continuation.resume(returning: AdapterBox(adapter: adapter))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return box.adapter
    }

    /// Internal: drives the initialized → opening → ready/failed transition.
    /// The adapter's synchronous local `open` runs on a background utility
    /// queue; the producer is returned (or the error surfaced) only after it
    /// completes.
    internal func performOpen() async throws {
        let validatedConfiguration = try configuration.validatedForOpen(
            requireDestination: requireDestinationOnOpen)
        let credentials = try credentialsForOpen()
        let didStart = withStateLock { () -> Bool in
            guard state == .initialized else { return false }
            state = .opening
            return true
        }
        guard didStart else {
            throw ProducerError.invalidState
        }

        let input = AdapterOpenInput(
            adapter: adapter,
            configuration: validatedConfiguration,
            credentials: credentials)

        do {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try input.adapter.open(
                            configuration: input.configuration,
                            credentials: input.credentials)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            withStateLock {
                state = .failed
            }
            throw error
        }

        // Release the plaintext copy now that the adapter has its own.
        withStateLock {
            snapshot = ConfigurationSnapshot(validatedConfiguration)
            openCredentials = nil
            state = .ready
        }
    }

    private final class AdapterOpenInput: @unchecked Sendable {
        let adapter: CoreAdapter
        let configuration: ProducerConfiguration
        let credentials: Credentials

        init(adapter: CoreAdapter,
             configuration: ProducerConfiguration,
             credentials: Credentials) {
            self.adapter = adapter
            self.configuration = configuration
            self.credentials = credentials
        }
    }

    private func credentialsForOpen() throws -> Credentials {
        guard let credentials = withStateLock({ openCredentials }) else {
            throw ProducerError.invalidState
        }
        try credentials.validate()
        return credentials
    }

    // MARK: - Public API

    /// Admits one log event.
    ///
    /// Synchronous and non-blocking on the network: it validates the event,
    /// snapshots it (value semantics), and hands it to the Core. Success
    /// means the event reached the local admission boundary of the
    /// configured durability, not that the server accepted it.
    ///
    /// - Throws: `ProducerError.invalidLog` if any field is invalid (the
    ///   whole event is rejected), `.singleLogTooLarge`, `.queueFull`,
    ///   `.bufferFull`, `.invalidState`, or `.closed`.
    public func add(_ log: LogEvent, mode: AddMode = .normal) throws {
        let state = withStateLock { self.state }
        try requireReadyState(state)

        // Validate before touching the adapter: an invalid event must never
        // reach the Core after the lifecycle state has been checked.
        try log.validate()
        guard !log.contents.isEmpty else {
            throw ProducerError.invalidLog([
                "contents: must contain at least one field"
            ])
        }

        let estimatedRawBytes = log.estimatedRawBytes()
        if estimatedRawBytes > snapshot.batch.maxRawBytes ||
            estimatedRawBytes > ProducerConfiguration.maxBatchRawBytes {
            throw ProducerError.singleLogTooLarge
        }

        // `log` is a value-type copy — the snapshot is taken here.
        try adapter.add(log, mode: mode)
    }

    /// Atomically replaces the whole credentials group.
    public func updateCredentials(_ credentials: Credentials) throws {
        let state = withStateLock { self.state }
        try requireReadyState(state)
        try credentials.validate()
        try adapter.updateCredentials(credentials)
    }

    /// Atomically replaces the whole destination. Previously accepted logs
    /// are later sent to the new destination (current-target semantics).
    public func updateDestination(_ destination: Destination) throws {
        let state = withStateLock { self.state }
        try requireReadyState(state)
        try destination.validate()
        try adapter.updateDestination(destination)
    }

    private func requireReadyState(_ state: State) throws {
        switch state {
        case .ready:
            return
        case .closed, .closing:
            throw ProducerError.closed
        case .initialized, .opening, .failed:
            throw ProducerError.invalidState
        }
    }

    /// Locally and safely stops the producer: seals pending batches, stops
    /// workers, and completes local persistence work within `timeout`.
    ///
    /// Success does NOT mean all accepted logs were delivered to the
    /// server. Concurrent callers waiting on the same close attempt receive
    /// the same outcome. After a failed attempt, a later call may retry the
    /// Core close; after success, later calls return success immediately.
    public func close(timeout: TimeInterval) async throws {
        try ProducerConfiguration.validateMilliseconds(
            timeout,
            name: "close.timeout",
            allowZero: true)

        let action = withStateLock { () -> CloseAction in
            switch state {
            case .closed:
                return .completed(closeResult ?? .success(()))
            case .ready:
                state = .closing
                let attempt = CloseAttempt()
                activeCloseAttempt = attempt
                return .start(attempt)
            case .closing:
                if let attempt = activeCloseAttempt {
                    return .wait(attempt)
                }
                // The preceding attempt failed. Keep rejecting add/update
                // while allowing this next call to retry the Core close.
                let attempt = CloseAttempt()
                activeCloseAttempt = attempt
                return .start(attempt)
            case .initialized, .opening, .failed:
                return .invalidState
            }
        }

        switch action {
        case .completed(let result):
            try result.get()
        case .wait(let attempt):
            try await attempt.wait()
        case .start(let attempt):
            do {
                try await adapter.close(timeout: timeout)
                finishClose(result: .success(()), attempt: attempt)
            } catch {
                finishClose(result: .failure(error), attempt: attempt)
                throw error
            }
        case .invalidState:
            throw ProducerError.invalidState
        }
    }

    private func finishClose(
        result: Result<Void, Error>,
        attempt: CloseAttempt
    ) {
        let shouldFinish = withStateLock {
            guard activeCloseAttempt === attempt else { return false }
            activeCloseAttempt = nil
            closeResult = result
            if case .success = result {
                state = .closed
            } else {
                // A failed close leaves the producer non-admissible but
                // retryable. A later close creates a fresh CloseAttempt.
                state = .closing
            }
            return true
        }
        if shouldFinish {
            attempt.finish(result)
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
