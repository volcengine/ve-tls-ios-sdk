//
//  RealCoreAdapter.swift
//  VolcengineTLSProducer/Core
//
//  Swift wrapper around the Objective-C bridge to ve-tls-c-sdk v0.3.1.
//

import Foundation

#if SWIFT_PACKAGE
import TLSProducerBridge
#else
@_implementationOnly import TLSProducerBridge
#endif

/// CoreAdapter backed by the vendored C Core.
///
/// The Objective-C bridge owns the Core/HTTP lifetimes. This layer owns the
/// public error mapping, sandbox directory preparation, lifecycle helper, and
/// Swift callback contract.
internal final class RealCoreAdapter: CoreAdapter, @unchecked Sendable {

    private enum CoreResult: Int {
        case ok = 0
        case invalid = 1
        case dropped = 2
        case persistence = 3
        case closed = 4
        case timeout = 5
    }

    private enum Operation {
        case open
        case add
        case updateCredentials
        case updateDestination
        case close
    }

    private let stateLock = NSLock()
    private var _onSendResult: (@Sendable (SendResult) -> Void)?
    private var opened = false
    private var closed = false
    private var lifecycleManager: TLSLifecycleManager?

    private let adapter: TLSRealCoreAdapter
    private let automaticLifecycleHandling: Bool
    private let callbackDeliveryQueue: DispatchQueue

    var onSendResult: (@Sendable (SendResult) -> Void)? {
        get { withStateLock { _onSendResult } }
        set { withStateLock { _onSendResult = newValue } }
    }

    init(configuration: ProducerConfiguration, credentials: Credentials) throws {
        guard let destination = configuration.destination else {
            throw ProducerError.configuration("destination is required")
        }
        try destination.validate()
        try credentials.validate()

        let persistentDirectory = try Self.preparePersistentDirectory(
            configuration: configuration)
        let persistenceMode: TLSRealCoreAdapterPersistenceMode
        switch configuration.persistence {
        case .disabled, .memory:
            persistenceMode = .disabled
        case .buffered:
            persistenceMode = .buffered
        case .sync:
            persistenceMode = .sync
        }

        // Preserve the serial callback guarantee even if the caller supplies
        // a concurrent queue: this private serial queue targets their queue.
        callbackDeliveryQueue = DispatchQueue(
            label: "com.volcengine.tls.producer.callback.delivery",
            qos: .utility,
            target: configuration.callbackQueue)
        automaticLifecycleHandling = configuration.automaticLifecycleHandling

        do {
            adapter = try TLSRealCoreAdapter(
                endpoint: destination.endpoint,
                region: destination.region,
                projectID: destination.projectID,
                topicID: destination.topicID,
                accessKeyID: credentials.accessKeyID,
                accessKeySecret: credentials.accessKeySecret,
                securityToken: credentials.securityToken,
                source: configuration.metadata.source,
                fileName: configuration.metadata.fileName,
                tags: configuration.metadata.tags.isEmpty ? nil : configuration.metadata.tags,
                maxLogCount: configuration.batch.maxLogCount,
                maxRawBytes: configuration.batch.maxRawBytes,
                linger: configuration.batch.linger,
                maxBufferBytes: configuration.buffer.maxBytes,
                connectTimeout: configuration.connectTimeout,
                requestTimeout: configuration.requestTimeout,
                lz4Enabled: configuration.compression == .lz4,
                sessionConfiguration: configuration.urlSessionConfiguration,
                bufferFullPolicy: configuration.buffer.fullPolicy == .block ? 1 : 0,
                sendConcurrency: configuration.sendConcurrency,
                bufferFullBlockTimeout: configuration.buffer.fullPolicy == .block
                    ? configuration.buffer.blockTimeout
                    : 0,
                persistenceMode: persistenceMode,
                persistentDirectory: persistentDirectory,
                maxLogAgeSeconds: Int(configuration.maxLogAge),
                expiredLogPolicy: configuration.expiredLogPolicy == .drop ? 1 : 0,
                authFailurePolicy: configuration.unauthorizedPolicy == .drop ? 1 : 0,
                callbackQueue: callbackDeliveryQueue)
        } catch {
            throw Self.mapBridgeError(error, operation: .open)
        }

        adapter.onSendResult = { [weak self] result,
            rawBytes,
            compressedBytes,
            httpCode,
            errorCode,
            errorMessage,
            requestID,
            transportKind,
            transportCode,
            retryable,
            _, _ in
            guard let self else { return }
            let producerError = Self.mapSendFailure(
                result: result,
                httpCode: httpCode,
                errorCode: errorCode,
                errorMessage: errorMessage,
                requestID: requestID,
                transportKind: transportKind,
                transportCode: transportCode,
                retryable: retryable)
            let sendResult = SendResult(
                status: result == CoreResult.ok.rawValue ? .success : .failure,
                rawBytes: Int(rawBytes),
                compressedBytes: Int(compressedBytes),
                requestID: requestID,
                error: producerError)
            self.onSendResult?(sendResult)
        }
    }

    deinit {
        transferLifecycleManagerReleaseToMainThread()
    }

    func open(configuration: ProducerConfiguration, credentials: Credentials) throws {
        let canOpen = withStateLock { !opened && !closed }
        guard canOpen else {
            throw withStateLock { closed }
                ? ProducerError.closed
                : ProducerError.invalidState
        }

        do {
            try adapter.open()
        } catch {
            throw Self.mapBridgeError(error, operation: .open)
        }
        withStateLock { opened = true }
        installLifecycleManagerIfNeeded()
    }

    func add(_ event: PreparedLogEvent, mode: AddMode) throws {
        try ensureOpen()
        do {
            // Swift Data bridges to an autoreleased NSData at the ObjC call.
            // A caller may perform a long synchronous add loop without ever
            // draining its own pool, so bound those bridge temporaries here.
            try autoreleasepool {
                try event.encodedLengths.withUnsafeBufferPointer { lengths in
                    try adapter.addLog(
                        withTimestamp: event.timestampMilliseconds,
                        nanosecondRemainder: event.timestampNanosecondsRemainder,
                        hashKey: event.hashKey,
                        fieldBytes: event.encodedFieldBytes,
                        lengths: lengths.baseAddress,
                        lengthCount: UInt(lengths.count),
                        flush: mode == .immediate)
                }
            }
        } catch {
            throw Self.mapBridgeError(error, operation: .add)
        }
    }

    /// Internal test convenience for exercising this adapter without the
    /// `Producer` facade. Public admission always passes a prepared snapshot.
    func add(_ event: LogEvent, mode: AddMode) throws {
        try add(event.prepareForAdmission(), mode: mode)
    }

    func updateCredentials(_ credentials: Credentials) throws {
        try ensureOpen()
        try credentials.validate()
        do {
            try adapter.updateCredentials(
                credentials.accessKeyID,
                accessKeySecret: credentials.accessKeySecret,
                securityToken: credentials.securityToken)
        } catch {
            throw Self.mapBridgeError(error, operation: .updateCredentials)
        }
    }

    func updateDestination(_ destination: Destination) throws {
        try ensureOpen()
        try destination.validate()
        do {
            try adapter.updateDestination(
                destination.endpoint,
                region: destination.region,
                projectID: destination.projectID,
                topicID: destination.topicID)
        } catch {
            throw Self.mapBridgeError(error, operation: .updateDestination)
        }
    }

    func close(timeout: TimeInterval) async throws {
        if withStateLock({ closed }) { return }

        removeLifecycleManager()
        do {
            // The C Core close joins worker threads and may consume the full
            // caller-provided timeout. Keep that bounded synchronous work off
            // the caller's executor (especially MainActor).
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    do {
                        try adapter.close(withTimeout: timeout)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            withStateLock { closed = true }
        } catch {
            throw Self.mapBridgeError(error, operation: .close)
        }
    }

    private func ensureOpen() throws {
        let state = withStateLock { (opened, closed) }
        if state.1 { throw ProducerError.closed }
        if !state.0 { throw ProducerError.invalidState }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // MARK: - Persistence

    private static func preparePersistentDirectory(
        configuration: ProducerConfiguration
    ) throws -> String? {
        switch configuration.persistence {
        case .disabled, .memory:
            return nil
        case .buffered, .sync:
            guard let producerID = configuration.producerID else {
                throw ProducerError.configuration(
                    "producerID is required when persistence is .buffered or .sync")
            }
            do {
                let directory = try TLSProducerDirectory.defaultDirectoryURL(
                    forProducerID: producerID)
                guard TLSProducerDirectory.isURL(
                    directory,
                    insideContainerBaseURL: nil) else {
                    throw ProducerError.persistence(
                        "producer directory is outside the application container")
                }
                return try TLSProducerDirectory.createDirectory(at: directory).path
            } catch let error as ProducerError {
                throw error
            } catch {
                throw ProducerError.persistence("producer directory preparation failed")
            }
        }
    }

    // MARK: - Lifecycle

    private func installLifecycleManagerIfNeeded() {
        guard automaticLifecycleHandling else { return }
        runOnMainSync {
            guard self.lifecycleManager == nil else { return }
            self.lifecycleManager = TLSLifecycleManager(
                flushHandler: { [weak self] in self?.adapter.flush() },
                wakeHandler: { [weak self] in self?.adapter.flush() })
        }
    }

    private func removeLifecycleManager() {
        runOnMainSync { self.lifecycleManager = nil }
    }

    private func transferLifecycleManagerReleaseToMainThread() {
        guard let manager = lifecycleManager else { return }
        lifecycleManager = nil
        if Thread.isMainThread {
            _ = manager
        } else {
            DispatchQueue.main.async { _ = manager }
        }
    }

    private func runOnMainSync(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    // MARK: - Error mapping

    private static func mapBridgeError(
        _ error: Error,
        operation: Operation
    ) -> ProducerError {
        if let producerError = error as? ProducerError {
            return producerError
        }
        let nsError = error as NSError
        if nsError.domain == TLSProducerDirectoryErrorDomain {
            return .persistence("producer directory operation failed")
        }
        guard nsError.domain == TLSRealCoreAdapterErrorDomain else {
            return .internal("adapter operation failed")
        }

        let resultValue = (nsError.userInfo[TLSRealCoreAdapterErrorResultKey] as? NSNumber)?
            .intValue
        let result = resultValue.flatMap(CoreResult.init(rawValue:))
        switch result {
        case .closed:
            return .closed
        case .timeout:
            return .timeout
        case .persistence:
            return .persistence("persistent Core operation failed")
        case .dropped where operation == .add:
            // v0.3.1 exposes one admission DROP result for both queue and
            // byte-budget exhaustion; classify conservatively as bufferFull.
            return .bufferFull
        case .invalid:
            return operation == .open
                ? .configuration("C Core rejected the configuration")
                : .internal("C Core rejected a validated operation")
        case .ok, .dropped, .none:
            break
        }

        if nsError.code == TLSRealCoreAdapterErrorCode.closed.rawValue {
            return .closed
        }
        if nsError.code == TLSRealCoreAdapterErrorCode.recoveryFailed.rawValue {
            return .persistence("persistent recovery failed")
        }
        if nsError.code == TLSRealCoreAdapterErrorCode.closeFailed.rawValue,
           operation == .close {
            return .internal("C Core close failed")
        }
        return .internal("C Core adapter operation failed")
    }

    static func mapSendFailure(
        result: Int32,
        httpCode: Int,
        errorCode: String?,
        errorMessage: String?,
        requestID: String?,
        transportKind: Int,
        transportCode: Int,
        retryable: Bool
    ) -> ProducerError? {
        guard result != CoreResult.ok.rawValue else { return nil }

        switch httpCode {
        case 401, 403:
            return .auth
        case 429:
            return .quota
        case let code where code > 0:
            return .service(
                code: code,
                message: errorCode ?? errorMessage ?? "service request failed",
                requestID: requestID)
        default:
            break
        }

        // The current C Core uses VE_TLS_TRANSPORT_GENERIC for some errors
        // produced before the HTTP adapter is entered. A zero transport code
        // plus one of these stable Core codes is therefore a local lifecycle,
        // capacity, or invariant failure—not a DNS/TLS/connect failure.
        // Classify it before the transport-kind fallback so public results do
        // not hide PayloadTooLarge/queue/buffer failures as `transport`.
        if transportCode == 0 {
            let normalized = errorCode?.lowercased() ?? ""
            switch normalized {
            case "producerclosed", "sendqueuestopped":
                return .closed
            case "keyqueuelimitexceeded", "sendqueuefull", "sendqueuetimeout":
                return .queueFull
            case "bufferfull", "bufferfulltimeout":
                return .bufferFull
            case "payloadtoolarge":
                return .internal("C Core rejected a validated batch size")
            case "memoryallocfailed", "clienterror", "credentialsrefreshfailed":
                return .internal("C Core failed before starting the HTTP request")
            default:
                break
            }
        }

        if result == CoreResult.timeout.rawValue || transportCode == 2103 {
            return .timeout
        }
        if transportCode == 2104 {
            return .cancelled
        }
        if transportKind != 0 {
            _ = retryable // retained for future public retry-state expansion
            return .transport(errorMessage ?? "HTTP transport failed")
        }

        switch CoreResult(rawValue: Int(result)) {
        case .persistence:
            return .persistence("persistent send failed")
        case .closed:
            return .closed
        case .dropped:
            let normalized = errorCode?.lowercased() ?? ""
            if normalized.contains("queue") { return .queueFull }
            if normalized.contains("persist") {
                return .persistence("persistent send failed")
            }
            return .bufferFull
        case .invalid:
            return .internal("C Core rejected a validated batch")
        case .timeout:
            return .timeout
        case .ok, .none:
            return .internal("C Core send failed")
        }
    }
}
