// FakeCoreAdapter.swift
// BridgeTests/Support
//
// TEST-ONLY FAKE IMPLEMENTATION. NOT FOR RELEASE. Does not perform network,
// persistence, signing, or real batching.
//
// CONTRACT ALIGNMENT:
//   - CoreAdapter is an internal protocol visible here through @testable.
//   - ProducerConfiguration carries an optional initial destination and is
//     revalidated at open.
//   - PreparedLogEvent.rawBytes is used for facade-equivalent accounting.
//
// Semantics implemented here mirror the frozen P0 contracts:
//   - add(.normal) enters the batch window; the batch seals when
//     count >= batch.maxLogCount, estimated raw bytes >= batch.maxRawBytes,
//     or the linger timer fires. add(.immediate) seals immediately after
//     admission (ledger O10). Delivery is always asynchronous.
//   - updateCredentials replaces the whole group atomically; each sealed
//     batch keeps its own credentials snapshot (no AK/SK/token mixing).
//   - updateDestination is current-target (ledger O2): every not-yet-delivered
//     batch is atomically retargeted; delivered batches keep their history.
//   - close(timeout:) is idempotent, rejects new adds with .closed, cancels
//     timers, and bounds the wait for in-flight callback delivery. On timeout
//     it gives up waiting; late terminal callbacks are STILL delivered to the
//     callback queue (exactly-once terminal contract per accepted batch;
//     weak self guarantees no UAF).
//   - onSendResult is never invoked under the internal lock; every callback
//     is dispatched to configuration.callbackQueue.
//

import Foundation
@testable import VolcengineTLSProducer

final class FakeCoreAdapter: CoreAdapter, @unchecked Sendable {

    // MARK: - Test observation surface

    /// Why a batch was sealed.
    public enum SealReason: String, Sendable {
        case maxCount
        case maxBytes
        case linger
        case immediate
        case close
    }

    /// A sealed batch snapshot. `credentials` is frozen at seal time;
    /// `destination` follows current-target semantics and may be rewritten by
    /// updateDestination until delivery (nil if no destination was ever set).
    /// `deliveredAt` is set when the terminal callback is delivered. Late
    /// delivery (after close timeout) still occurs, so this is non-nil for
    /// every sealed batch once its callback runs.
    public struct SealedBatch: @unchecked Sendable {
        public let id: Int
        public let events: [LogEvent]
        public let rawBytes: Int
        /// Fake does not compress; always equal to rawBytes.
        public let compressedBytes: Int
        public let requestID: String
        public let credentials: Credentials
        // internal(set), not private(set): the enclosing FakeCoreAdapter
        // (parent type) must be able to rewrite these, and Swift `private`
        // is scoped to SealedBatch itself, not its enclosing type.
        public internal(set) var destination: Destination?
        public let sealedAt: Date
        public let sealReason: SealReason
        public internal(set) var deliveredAt: Date?

        public init(id: Int,
                    events: [LogEvent],
                    rawBytes: Int,
                    compressedBytes: Int,
                    requestID: String,
                    credentials: Credentials,
                    destination: Destination?,
                    sealedAt: Date,
                    sealReason: SealReason,
                    deliveredAt: Date? = nil) {
            self.id = id
            self.events = events
            self.rawBytes = rawBytes
            self.compressedBytes = compressedBytes
            self.requestID = requestID
            self.credentials = credentials
            self.destination = destination
            self.sealedAt = sealedAt
            self.sealReason = sealReason
            self.deliveredAt = deliveredAt
        }
    }

    // MARK: - State

    private enum State {
        case initialized
        case ready
        case closing
        case closed
    }

    private let lock = NSLock()
    private var state: State = .initialized
    private var configuration: ProducerConfiguration?
    private var credentials: Credentials?
    private var destination: Destination?

    private var currentBatchEvents: [LogEvent] = []
    private var currentBatchRawBytes: Int = 0
    private var lingerWorkItem: DispatchWorkItem?

    private var admitted: [LogEvent] = []
    private var sealed: [SealedBatch] = []
    private var nextBatchID: Int = 1
    private var nextRequestNumber: Int = 1

    /// Deliveries dispatched to the callback queue that have not yet finished.
    private var pendingDeliveries: Int = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    private let timerQueue = DispatchQueue(
        label: "com.volcengine.tls.producer.fakecore.timer")

    // MARK: - Public knobs / observation

    /// Terminal-result handler. CONTRACT: set once before `open` and not
    /// replaced at runtime (mirrors the CoreAdapter seam contract; the Fake
    /// does not enforce set-once — tests that swap it do so at their own
    /// risk).
    public var onSendResult: (@Sendable (SendResult) -> Void)?

    /// TEST-ONLY knob. When non-nil, every `add` throws this error after the
    /// state check. Does not affect `open`. Never set in release code paths.
    public var stubbedAdmissionError: ProducerError?

    /// When > 0, `close` suspends for this duration after the synchronous
    /// state transition (new adds already rejected) and before waiting for
    /// in-flight deliveries. Test hook for close/cancel races.
    public var artificialCloseDelay: TimeInterval = 0

    /// Number of close entries that took the non-fast-path (state
    /// `.ready`/`.initialized`), i.e. entries that perform real shutdown
    /// work. Concurrent `.closing` joins and the `.closed` idempotent fast
    /// path are NOT counted.
    public private(set) var closeCallCount: Int = 0

    /// Snapshot of every admitted event, in admission order.
    public var admittedEvents: [LogEvent] {
        lock.lock(); defer { lock.unlock() }
        return admitted
    }

    /// Snapshot of every sealed batch, in seal order.
    public var sealedBatches: [SealedBatch] {
        lock.lock(); defer { lock.unlock() }
        return sealed
    }

    public var currentCredentials: Credentials? {
        lock.lock(); defer { lock.unlock() }
        return credentials
    }

    public var currentDestination: Destination? {
        lock.lock(); defer { lock.unlock() }
        return destination
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .closed
    }

    // MARK: - CoreAdapter

    public init() {}

    public func open(configuration: ProducerConfiguration,
                     credentials: Credentials) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .initialized else {
            throw ProducerError.invalidState
        }
        self.configuration = configuration
        self.credentials = credentials
        // Destination is NOT part of open; it arrives via updateDestination.
        self.state = .ready
    }

    func add(_ prepared: PreparedLogEvent, mode: AddMode) throws {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .initialized:
            throw ProducerError.invalidState
        case .closing, .closed:
            throw ProducerError.closed
        case .ready:
            break
        }
        if let stub = stubbedAdmissionError {
            throw stub
        }

        admitted.append(prepared.event)
        currentBatchEvents.append(prepared.event)
        currentBatchRawBytes += prepared.rawBytes

        switch mode {
        case .immediate:
            // Ledger O10: seal immediately after admission; still async,
            // never waits for network/ACK.
            cancelLingerLocked()
            sealCurrentBatchLocked(reason: .immediate)
        case .normal:
            let batchConfig = configuration!.batch
            if currentBatchEvents.count >= batchConfig.maxLogCount {
                cancelLingerLocked()
                sealCurrentBatchLocked(reason: .maxCount)
            } else if currentBatchRawBytes >= batchConfig.maxRawBytes {
                cancelLingerLocked()
                sealCurrentBatchLocked(reason: .maxBytes)
            } else {
                scheduleLingerLocked()
            }
        }
    }

    /// Test-only convenience for exercising the fake without the facade.
    public func add(_ event: LogEvent, mode: AddMode) throws {
        try add(event.prepareForAdmission(), mode: mode)
    }

    public func updateCredentials(_ credentials: Credentials) throws {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .ready:
            break
        case .initialized:
            throw ProducerError.invalidState
        case .closing, .closed:
            throw ProducerError.closed
        }
        // Whole-group atomic replacement. Sealed batches captured their own
        // snapshot at seal time, so in-flight batches never mix AK/SK/token.
        self.credentials = credentials
    }

    public func updateDestination(_ destination: Destination) throws {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .ready:
            break
        case .initialized:
            throw ProducerError.invalidState
        case .closing, .closed:
            throw ProducerError.closed
        }
        // Ledger O2 current-target semantics: every not-yet-delivered batch
        // is atomically retargeted. Delivered batches keep their history.
        self.destination = destination
        for index in sealed.indices where sealed[index].deliveredAt == nil {
            sealed[index].destination = destination
        }
    }

    public func close(timeout: TimeInterval) async throws {
        let shouldWait = withLock { () -> Bool in
            if state == .closed {
                // Idempotent fast path (not counted).
                return false
            }
            if state == .ready || state == .initialized {
                // Only the entry that performs real shutdown is counted;
                // concurrent .closing joins below are not.
                closeCallCount += 1
            }
            if state == .initialized {
                state = .closed
                return false
            }
            if state == .ready {
                state = .closing
                cancelLingerLocked()
                // Bounded flush: seal the pending batch (if any) and let its
                // delivery be awaited below.
                sealCurrentBatchLocked(reason: .close)
                if pendingDeliveries == 0 {
                    state = .closed
                    return false
                }
            }
            // If state == .closing (concurrent close), register a waiter
            // without counting it.
            return true
        }
        guard shouldWait else { return }

        if artificialCloseDelay > 0 {
            // Test hook; cancellation must not break finalization.
            try? await Task.sleep(nanoseconds:
                UInt64(artificialCloseDelay * 1_000_000_000))
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyClosed = withLock { () -> Bool in
                if state == .closed {
                    return true
                }
                closeWaiters.append(continuation)
                return false
            }
            if alreadyClosed {
                continuation.resume()
                return
            }
            scheduleCloseTimeout(timeout)
        }
    }

    // MARK: - Sealing / delivery (private)

    /// Must be called with `lock` held.
    private func scheduleLingerLocked() {
        guard lingerWorkItem == nil else { return }
        guard let config = configuration, config.batch.linger > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            // Clear the slot FIRST so a subsequent add(.normal) can schedule
            // a fresh linger timer (otherwise the timer dies after one fire).
            self.lingerWorkItem = nil
            guard self.state == .ready else { return }
            self.sealCurrentBatchLocked(reason: .linger)
        }
        lingerWorkItem = work
        timerQueue.asyncAfter(deadline: .now() + config.batch.linger, execute: work)
    }

    /// Must be called with `lock` held.
    private func cancelLingerLocked() {
        lingerWorkItem?.cancel()
        lingerWorkItem = nil
    }

    /// Must be called with `lock` held. Seals the current batch and queues
    /// the terminal delivery asynchronously on the callback queue.
    private func sealCurrentBatchLocked(reason: SealReason) {
        guard !currentBatchEvents.isEmpty,
              let config = configuration,
              let creds = credentials else { return }
        let events = currentBatchEvents
        let rawBytes = currentBatchRawBytes
        currentBatchEvents = []
        currentBatchRawBytes = 0

        let batch = SealedBatch(
            id: nextBatchID,
            events: events,
            rawBytes: rawBytes,
            compressedBytes: rawBytes, // Fake does not compress.
            requestID: "fake-req-\(nextRequestNumber)",
            credentials: creds,
            destination: destination, // nil until updateDestination is called
            sealedAt: Date(),
            sealReason: reason)
        nextBatchID += 1
        nextRequestNumber += 1
        sealed.append(batch)
        pendingDeliveries += 1

        let queue = config.callbackQueue
        queue.async { [weak self, batch] in
            guard let self = self else { return }
            self.lock.lock()
            if let index = self.sealed.firstIndex(where: { $0.id == batch.id }) {
                self.sealed[index].deliveredAt = Date()
            }
            self.lock.unlock()

            // Late delivery (after close timeout) is STILL delivered: the
            // CoreAdapter seam promises exactly one terminal SendResult per
            // accepted batch. weak self guarantees no UAF; the block never
            // touches freed state.
            let result = SendResult(
                status: .success,
                rawBytes: batch.rawBytes,
                compressedBytes: batch.compressedBytes,
                requestID: batch.requestID,
                error: nil)
            self.onSendResult?(result)
            self.finishDelivery()
        }
    }

    /// Called after a delivery block finishes (delivered or dropped).
    private func finishDelivery() {
        lock.lock()
        pendingDeliveries = max(0, pendingDeliveries - 1)
        var waiters: [CheckedContinuation<Void, Never>] = []
        if state == .closing && pendingDeliveries == 0 {
            state = .closed
            waiters = closeWaiters
            closeWaiters = []
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Bounds the close wait: if deliveries do not finish before the timeout,
    /// give up waiting and mark closed; late deliveries will drop.
    private func scheduleCloseTimeout(_ timeout: TimeInterval) {
        let bounded = max(0, timeout)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bounded) {
            [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            var waiters: [CheckedContinuation<Void, Never>] = []
            if self.state == .closing {
                self.state = .closed
                waiters = self.closeWaiters
                self.closeWaiters = []
            }
            self.lock.unlock()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    deinit {
        lingerWorkItem?.cancel()
    }
}
