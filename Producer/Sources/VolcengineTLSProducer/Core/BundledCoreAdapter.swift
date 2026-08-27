//
//  BundledCoreAdapter.swift
//  VolcengineTLSProducer/Core
//
//  Worker A — PROVISIONAL placeholder until RealCoreAdapter gate;
//  NOT a release behavior claim.
//

import Foundation

/// Minimal in-memory `CoreAdapter` used by `Producer.open` until the real
/// C Core is integrated.
///
/// PROVISIONAL placeholder until RealCoreAdapter gate; NOT a release
/// behavior claim. Behavior:
/// - Normal and immediate modes only perform in-memory batching.
/// - Batches seal on: `AddMode.immediate`, `batch.maxLogCount`,
///   `batch.maxRawBytes`, or `batch.linger`.
/// - Every sealed batch produces one successful `SendResult` delivered
///   asynchronously on `configuration.callbackQueue`.
/// - No network, no persistence, no compression, no retry, no signing.
///   `compressedBytes` mirrors `rawBytes` because no compression runs.
/// - Buffer capacity (`buffer.maxBytes`) is enforced across admitted but
///   not yet reported bytes; overflow throws `.bufferFull`.
/// - `BufferFullPolicy.block` is NOT honored by this placeholder: it
///   degrades to `.reject` (fail-fast). The blocking policy will be
///   implemented by the RealCoreAdapter (Wave 3); do not rely on it before
///   then.
/// - The linger timer currently shares `configuration.callbackQueue`; a
///   user handler that blocks delays sealing. RealCoreAdapter will use a
///   dedicated timer queue (see FakeCoreAdapter.timerQueue).
///
/// Locking: `lock` guards state/batch/bufferedBytes. `drainCondition`
/// guards `pendingCallbacks` and is used by `close` to bound the wait for
/// terminal callbacks. Nested lock order is always `lock` →
/// `drainCondition`, never the reverse.
internal final class BundledCoreAdapter: CoreAdapter {

    var onSendResult: (@Sendable (SendResult) -> Void)?

    private enum State {
        case initialized
        case open
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
        case .closed:
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
        case .closed:
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
        case .closed:
            throw ProducerError.closed
        case .initialized:
            throw ProducerError.invalidState
        }
        // No-op beyond the state check: the in-memory adapter has no
        // connection to re-target.
        _ = destination
    }

    func close(timeout: TimeInterval) async {
        lock.lock()
        guard state == .open else {
            lock.unlock()
            return
        }
        state = .closed
        lingerWorkItem?.cancel()
        lingerWorkItem = nil
        sealLocked() // nests drainCondition under lock (fixed order)
        lock.unlock()

        drainCondition.lock()
        let needWait = pendingCallbacks > 0
        drainCondition.unlock()
        guard needWait else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(max(0, timeout))
                self.drainCondition.lock()
                while self.pendingCallbacks > 0 {
                    if !self.drainCondition.wait(until: deadline) {
                        break // timeout: local stop proceeds regardless
                    }
                }
                self.drainCondition.unlock()
                cont.resume()
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

    private static let fallbackQueue = DispatchQueue(
        label: "com.volcengine.tls.producer.callback",
        qos: .utility)
}
