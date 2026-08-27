//
//  RecordingAdapter.swift
//  ContractTests/Support
//
//  Worker A — CoreAdapter spy for contract tests. Test-only; never ships.
//

import Foundation
import XCTest
@testable import VolcengineTLSProducer

/// Thread-safe `CoreAdapter` spy recording every call and allowing error
/// injection and manual `SendResult` emission.
final class RecordingAdapter: CoreAdapter {

    var onSendResult: (@Sendable (SendResult) -> Void)?

    private let lock = NSLock()
    private var _openCallCount = 0
    private var _addCalls: [(event: LogEvent, mode: AddMode)] = []
    private var _updateCredentialsCalls: [Credentials] = []
    private var _updateDestinationCalls: [Destination] = []
    private var _closeCallCount = 0
    private var _configuration: ProducerConfiguration?

    /// When set, `open` throws this error.
    var openError: Error?
    /// When set, `add` throws this error.
    var addError: Error?

    /// Signaled once `open` has started (after recording the call).
    let openStarted = DispatchSemaphore(value: 0)
    /// `open` blocks on this semaphore when non-nil, letting tests exercise
    /// the `.opening` state.
    var openGate: DispatchSemaphore?

    init() {}

    // MARK: - Observation

    var openCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _openCallCount
    }

    var addCalls: [(event: LogEvent, mode: AddMode)] {
        lock.lock(); defer { lock.unlock() }
        return _addCalls
    }

    var updateCredentialsCalls: [Credentials] {
        lock.lock(); defer { lock.unlock() }
        return _updateCredentialsCalls
    }

    var updateDestinationCalls: [Destination] {
        lock.lock(); defer { lock.unlock() }
        return _updateDestinationCalls
    }

    var closeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _closeCallCount
    }

    // MARK: - CoreAdapter

    func open(configuration: ProducerConfiguration, credentials: Credentials) throws {
        lock.lock()
        _openCallCount += 1
        _configuration = configuration
        let error = openError
        let gate = openGate
        lock.unlock()

        openStarted.signal()
        gate?.wait()

        if let error = error {
            throw error
        }
    }

    func add(_ event: LogEvent, mode: AddMode) throws {
        lock.lock()
        _addCalls.append((event, mode))
        let error = addError
        lock.unlock()
        if let error = error {
            throw error
        }
    }

    func updateCredentials(_ credentials: Credentials) throws {
        lock.lock()
        _updateCredentialsCalls.append(credentials)
        lock.unlock()
    }

    func updateDestination(_ destination: Destination) throws {
        lock.lock()
        _updateDestinationCalls.append(destination)
        lock.unlock()
    }

    func close(timeout: TimeInterval) async {
        lock.lock()
        _closeCallCount += 1
        lock.unlock()
        // Yield once so concurrent-close tests exercise the .closing state.
        await Task.yield()
    }

    // MARK: - Emission

    /// Delivers a result on the configured callback queue (or a private
    /// serial queue when `open` was never called).
    func emit(_ result: SendResult) {
        lock.lock()
        let queue = _configuration?.callbackQueue ?? RecordingAdapter.fallbackQueue
        lock.unlock()
        queue.async { [weak self] in
            self?.onSendResult?(result)
        }
    }

    private static let fallbackQueue = DispatchQueue(
        label: "com.volcengine.tls.producer.contracttests.recording",
        qos: .utility)
}

// MARK: - Test helpers

extension ProducerConfiguration {
    /// Default configuration for contract tests.
    static func makeTesting() throws -> ProducerConfiguration {
        return try ProducerConfiguration()
    }
}

extension Credentials {
    static let testing = Credentials(
        accessKeyID: "test-ak",
        accessKeySecret: "test-sk",
        securityToken: "test-token")
}

extension Destination {
    static let testing = Destination(
        endpoint: "https://tls-cn-beijing.volces.com",
        region: "cn-beijing",
        projectID: "test-project",
        topicID: "test-topic")
}

/// Polls `condition` until true or the deadline. Fails the test on timeout.
func waitUntil(
    timeout: TimeInterval = 2,
    file: StaticString = #file,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            XCTFail("waitUntil timed out", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
    }
}
