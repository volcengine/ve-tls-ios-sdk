//
//  BundledCoreAdapter.swift
//  VolcengineTLSProducer/Core
//
//  Deterministic in-memory adapter for package-internal contract tests.
//

import Foundation

/// Minimal in-memory `CoreAdapter` used only through the internal injection
/// seam in contract tests. Public `Producer.open` always builds the real Core.
///
/// This is not release behavior. It deliberately models only the facade
/// lifecycle/batching contract:
/// - Normal and immediate modes only perform in-memory batching.
/// - Batches seal on: `AddMode.immediate`, `batch.maxLogCount`,
///   `batch.maxRawBytes`, or `batch.linger`.
/// - Every sealed batch produces one successful `SendResult` delivered
///   asynchronously on `configuration.callbackQueue`.
/// - No network, no persistence, no compression, no retry, no signing.
///   `compressedBytes` mirrors `rawBytes` because no compression runs.
/// - Buffer capacity (`buffer.maxBytes`) is enforced across admitted but
///   not yet reported bytes; overflow throws `.bufferFull`.
/// - `BufferFullPolicy.block` is not modeled; it degrades to `.reject`.
/// - The linger timer currently shares `configuration.callbackQueue`; a
///   user handler that blocks delays sealing. The real Core does not use this
///   implementation.
///
/// Locking: `lock` guards state/batch/bufferedBytes. `drainCondition`
/// guards `pendingCallbacks` and is used by `close` to bound the wait for
/// terminal callbacks. Nested lock order is always `lock` →
/// `drainCondition`, never the reverse.
internal final class BundledCoreAdapter: CoreAdapter, @unchecked Sendable {

    var onSendResult: (@Sendable (SendResult) -> Void)?

    private enum State {
        case initialized
        case open
        case closing
        case closed
    }

    private let lock = NSLock()
    private let drainCondition = NSCondition()
    private var state: State = .initialized
    private var configuration: ProducerConfiguration?

    // Current (unsealed) batch.
    private var batchEvents: [LogEvent] = []
    private var batchRawBytes: Int = 0

    // Total bytes admitted but not yet reported via a terminal callback.
    private var bufferedBytes: Int = 0

    // Pending terminal callbacks (for bounded close). Guarded by
    // `drainCondition`.
    private var pendingCallbacks: Int = 0

    private var lingerWorkItem: DispatchWorkItem?

    init() {}

    // MARK: - CoreAdapter

    func open(configuration: ProducerConfiguration, credentials: Credentials) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .initialized else {
            throw ProducerError.invalidState
        }
        self.configuration = configuration
        // Credentials are irrelevant for the in-memory adapter; they are not
        // retained here. The Producer owns the atomic-update contract.
        _ = credentials
        state = .open
    }

    func add(_ event: LogEvent, mode: AddMode) throws {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .open:
            break
        case .closing, .closed:
            throw ProducerError.closed
        case .initialized:
            throw ProducerError.invalidState
        }

        let size = event.estimatedRawBytes()
        let bufferMax = configuration?.buffer.maxBytes ?? (64 * 1024 * 1024)
        if bufferedBytes + size > bufferMax {
            throw ProducerError.bufferFull
        }

        batchEvents.append(event)
        batchRawBytes += size
        bufferedBytes += size

        let maxCount = configuration?.batch.maxLogCount ?? 1024
        let maxBytes = configuration?.batch.maxRawBytes ?? (1024 * 1024)

        if mode == .immediate
            || batchEvents.count >= maxCount
            || batchRawBytes >= maxBytes {
            sealLocked()
        } else {
            scheduleLingerLocked()
        }
    }

    func updateCredentials(_ credentials: Credentials) throws {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .open:
            break
        case .closing, .closed:
            throw ProducerError.closed
        case .initialized:
            throw ProducerError.invalidState
        }
        // No-op beyond the state check: the in-memory adapter performs no
        // network and therefore no signing.
        _ = credentials
    }

    func updateDestination(_ destination: Destination) throws {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .open:
            break
        case .closing, .closed:
            throw ProducerError.closed
        case .initialized:
            throw ProducerError.invalidState
        }
        // No-op beyond the state check: the in-memory adapter has no
        // connection to re-target.
        _ = destination
    }

    func close(timeout: TimeInterval) async throws {
        let needWait = withStateLock {
            switch state {
            case .initialized:
                state = .closed
                return false
            case .closed:
                return false
            case .open:
                state = .closing
                lingerWorkItem?.cancel()
                lingerWorkItem = nil
                sealLocked() // nests drainCondition under lock (fixed order)
            case .closing:
                break
            }
            return withDrainConditionLock { pendingCallbacks > 0 }
        }
        if !needWait {
            withStateLock {
                if state == .closing {
                    state = .closed
                }
            }
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(max(0, timeout))
                self.withDrainConditionLock {
                    while self.pendingCallbacks > 0 {
                        if !self.drainCondition.wait(until: deadline) {
                            break // timeout is reported after this scope
                        }
                    }
                }
                cont.resume()
            }
        }

        let drained = withDrainConditionLock { pendingCallbacks == 0 }
        guard drained else {
            // Keep the adapter in .closing so a later close can retry the
            // bounded drain after the callback queue makes progress.
            throw ProducerError.timeout
        }
        withStateLock {
            if state == .closing {
                state = .closed
            }
        }
    }

    // MARK: - Batching internals (lock held by caller)

    private func scheduleLingerLocked() {
        if lingerWorkItem != nil { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if self.state == .open && !self.batchEvents.isEmpty {
                self.sealLocked()
            }
            self.lingerWorkItem = nil
            self.lock.unlock()
        }
        lingerWorkItem = item
        let linger = configuration?.batch.linger ?? 3
        let queue = configuration?.callbackQueue
            ?? BundledCoreAdapter.fallbackQueue
        queue.asyncAfter(deadline: .now() + linger, execute: item)
    }

    /// Seals the current batch and schedules its terminal callback.
    /// Caller must hold `lock`.
    private func sealLocked() {
        guard !batchEvents.isEmpty else { return }
        let rawBytes = batchRawBytes
        batchEvents.removeAll(keepingCapacity: false)
        batchRawBytes = 0
        lingerWorkItem?.cancel()
        lingerWorkItem = nil

        drainCondition.lock()
        pendingCallbacks += 1
        drainCondition.unlock()

        let queue = configuration?.callbackQueue
            ?? BundledCoreAdapter.fallbackQueue
        queue.async { [weak self] in
            guard let self = self else { return }
            // No compression in the bundled adapter: compressed mirrors raw.
            let result = SendResult(
                status: .success,
                rawBytes: rawBytes,
                compressedBytes: rawBytes,
                requestID: nil,
                error: nil)
            self.onSendResult?(result)
            self.callbackFinished(sealedBytes: rawBytes)
        }
    }

    private func callbackFinished(sealedBytes: Int) {
        lock.lock()
        bufferedBytes -= sealedBytes
        lock.unlock()

        drainCondition.lock()
        pendingCallbacks -= 1
        if pendingCallbacks == 0 {
            drainCondition.broadcast()
        }
        drainCondition.unlock()
    }

    // Synchronous lock scopes keep NSLock.lock/unlock out of async function
    // bodies, which is required by strict Swift 6 concurrency checking while
    // remaining available on Swift 5.8/iOS 13.
    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func withDrainConditionLock<T>(_ body: () -> T) -> T {
        drainCondition.lock()
        defer { drainCondition.unlock() }
        return body()
    }

    private static let fallbackQueue = DispatchQueue(
        label: "com.volcengine.tls.producer.callback",
        qos: .utility)
}
