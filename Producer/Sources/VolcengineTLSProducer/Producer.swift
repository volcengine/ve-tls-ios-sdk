//
//  Producer.swift
//  VolcengineTLSProducer
//
//  Worker A — public lifecycle facade.
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
public final class Producer {

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
    private var closeWaiters: [CheckedContinuation<Void, Error>] = []

    private let adapter: CoreAdapter
    private let configuration: ProducerConfiguration
    private let snapshot: ConfigurationSnapshot
    private var openCredentials: Credentials?
    private let userOnSendResult: (@Sendable (SendResult) -> Void)?

    /// Internal injection point for tests and for the future
    /// `RealCoreAdapter`. Not part of the public API.
    internal init(adapter: CoreAdapter,
                  configuration: ProducerConfiguration,
                  credentials: Credentials,
                  onSendResult: (@Sendable (SendResult) -> Void)?) {
        self.adapter = adapter
        self.configuration = configuration
        self.snapshot = ConfigurationSnapshot(configuration)
        self.openCredentials = credentials
        self.userOnSendResult = onSendResult

        // The adapter guarantees delivery on configuration.callbackQueue and
        // never calls back under a lock (see CoreAdapter contract). The
        // Producer therefore forwards to the user handler directly.
        adapter.onSendResult = { [weak self] result in
            guard let self = self else { return }
            self.lock.lock()
            let handler = self.userOnSendResult
            self.lock.unlock()
            handler?(result)
        }
    }

    /// Opens a producer with the bundled in-memory adapter.
    ///
    /// NOTE: the bundled adapter is a PROVISIONAL placeholder until the
    /// RealCoreAdapter gate; it performs no network/persistence. Do not
    /// read its behavior as a release claim.
    public static func open(
        configuration: ProducerConfiguration,
        credentials: Credentials,
        onSendResult: (@Sendable (SendResult) -> Void)? = nil
    ) async throws -> Producer {
        let producer = Producer(
            adapter: BundledCoreAdapter(),
            configuration: configuration,
            credentials: credentials,
            onSendResult: onSendResult)
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
        let producer = Producer(
            adapter: adapter,
            configuration: configuration,
            credentials: credentials,
            onSendResult: onSendResult)
        try await producer.performOpen()
        return producer
    }

    /// Internal: drives the initialized → opening → ready/failed transition.
    /// The adapter's synchronous local `open` runs on a background utility
    /// queue; the producer is returned (or the error surfaced) only after it
    /// completes.
    internal func performOpen() async throws {
        lock.lock()
        guard state == .initialized else {
            lock.unlock()
            throw ProducerError.invalidState
        }
        state = .opening
        lock.unlock()

        guard let credentials = openCredentials else {
            // openCredentials is set in init and cleared only after a
            // successful open; reaching here means open ran twice.
            lock.lock()
            state = .failed
            lock.unlock()
            throw ProducerError.invalidState
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedThrowingContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try self.adapter.open(
                            configuration: self.configuration,
                            credentials: credentials)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } catch {
            lock.lock()
            state = .failed
            lock.unlock()
            throw error
        }

        // Release the plaintext copy now that the adapter has its own.
        lock.lock()
        openCredentials = nil
        state = .ready
        lock.unlock()
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
        // Validate before touching any shared state: an invalid event must
        // never reach the adapter.
        try log.validate()

        lock.lock()
        let state = self.state
        lock.unlock()
        switch state {
        case .ready:
            break
        case .closed, .closing:
            throw ProducerError.closed
        case .initialized, .opening, .failed:
            throw ProducerError.invalidState
        }

        if log.estimatedRawBytes() > snapshot.batch.maxRawBytes {
            throw ProducerError.singleLogTooLarge
        }

        // `log` is a value-type copy — the snapshot is taken here.
        try adapter.add(log, mode: mode)
    }

    /// Atomically replaces the whole credentials group.
    public func updateCredentials(_ credentials: Credentials) throws {
        lock.lock()
        let state = self.state
        lock.unlock()
        switch state {
        case .ready:
            break
        case .closed, .closing:
            throw ProducerError.closed
        case .initialized, .opening, .failed:
            throw ProducerError.invalidState
        }
        try adapter.updateCredentials(credentials)
    }

    /// Atomically replaces the whole destination. Previously accepted logs
    /// are later sent to the new destination (current-target semantics).
    public func updateDestination(_ destination: Destination) throws {
        try destination.validate()
        lock.lock()
        let state = self.state
        lock.unlock()
        switch state {
        case .ready:
            break
        case .closed, .closing:
            throw ProducerError.closed
        case .initialized, .opening, .failed:
            throw ProducerError.invalidState
        }
        try adapter.updateDestination(destination)
    }

    /// Locally and safely stops the producer: seals pending batches, stops
    /// workers, and completes local persistence work within `timeout`.
    ///
    /// Success does NOT mean all accepted logs were delivered to the
    /// server. Idempotent: a second call returns the same outcome (waiting
    /// for the in-flight shutdown if necessary).
    public func close(timeout: TimeInterval) async throws {
        lock.lock()
        switch state {
        case .closed:
            let result = closeResult ?? .success(())
            lock.unlock()
            try result.get()
            return
        case .closing:
            // Join the in-flight shutdown.
            lock.unlock()
            try await withCheckedThrowingContinuation { (cont: CheckedThrowingContinuation<Void, Error>) in
                self.lock.lock()
                if let finished = self.closeResult {
                    self.lock.unlock()
                    cont.resume(with: finished)
                    return
                }
                self.closeWaiters.append(cont)
                self.lock.unlock()
            }
            return
        case .ready:
            state = .closing
            lock.unlock()
        case .initialized, .opening, .failed:
            lock.unlock()
            throw ProducerError.invalidState
        }

        // Bounded local shutdown. The adapter contract forbids throwing;
        // timeout means "stop waiting", not failure of the local stop.
        await adapter.close(timeout: timeout)
        finishClose(result: .success(()))
    }

    private func finishClose(result: Result<Void, Error>) {
        lock.lock()
        state = .closed
        closeResult = result
        let waiters = closeWaiters
        closeWaiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}
