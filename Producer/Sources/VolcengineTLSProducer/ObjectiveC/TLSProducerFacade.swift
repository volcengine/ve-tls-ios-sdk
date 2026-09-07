//
// TLSProducerFacade.swift
// VolcengineTLSProducer
//
// Objective-C compatibility facade for the value-typed Swift producer API.
// This file intentionally depends only on the public Swift Producer models;
// the CoreAdapter and its private bridge remain below this boundary.
//

import Foundation

// MARK: - Objective-C enums

/// Buffer admission policy exposed to Objective-C callers.
@objc(TLSBufferFullPolicy)
public enum TLSBufferFullPolicy: Int {
    case reject = 0
    case block = 1
}

/// Outgoing batch compression exposed to Objective-C callers.
@objc(TLSCompression)
public enum TLSCompression: Int {
    case disabled = 0
    case lz4 = 1
}

/// Persistence mode exposed to Objective-C callers.
@objc(TLSPersistence)
public enum TLSPersistence: Int {
    case disabled = 0
    case memory = 1
    case buffered = 2
    case sync = 3
}

/// Expired-log policy exposed to Objective-C callers.
@objc(TLSExpiredLogPolicy)
public enum TLSExpiredLogPolicy: Int {
    case rewriteTimestamp = 0
    case drop = 1
}

/// Unauthorized-response policy exposed to Objective-C callers.
@objc(TLSUnauthorizedPolicy)
public enum TLSUnauthorizedPolicy: Int {
    case retain = 0
    case drop = 1
}

/// Admission mode exposed to Objective-C callers.
@objc(TLSAddMode)
public enum TLSAddMode: Int {
    case normal = 0
    case immediate = 1
}

/// Send-result status exposed to Objective-C callers.
@objc(TLSSendResultStatus)
public enum TLSSendResultStatus: Int {
    case success = 0
    case failure = 1
}

/// Stable numeric NSError codes for the Objective-C facade.
///
/// These values are deliberately assigned rather than derived from enum
/// ordering. The corresponding stable string is stored in NSError userInfo
/// under `TLSProducer.errorCodeKey`.
@objc(TLSProducerErrorCode)
public enum TLSProducerErrorCode: Int {
    case unknown = 0
    case configuration = 1
    case invalidLog = 2
    case invalidState = 3
    case queueFull = 4
    case bufferFull = 5
    case singleLogTooLarge = 6
    case persistence = 7
    case transport = 8
    case service = 9
    case auth = 10
    case quota = 11
    case timeout = 12
    case cancelled = 13
    case closed = 14
    case `internal` = 15
}

// MARK: - Swift model mappings

private extension TLSBufferFullPolicy {
    var swiftValue: BufferFullPolicy? {
        switch self {
        case .reject:
            return .reject
        case .block:
            return .block
        default:
            return nil
        }
    }
}

private extension TLSCompression {
    var swiftValue: Compression? {
        switch self {
        case .disabled:
            return .disabled
        case .lz4:
            return .lz4
        default:
            return nil
        }
    }
}

private extension TLSPersistence {
    var swiftValue: Persistence? {
        switch self {
        case .disabled:
            return .disabled
        case .memory:
            return .memory
        case .buffered:
            return .buffered
        case .sync:
            return .sync
        default:
            return nil
        }
    }
}

private extension TLSExpiredLogPolicy {
    var swiftValue: ExpiredLogPolicy? {
        switch self {
        case .rewriteTimestamp:
            return .rewriteTimestamp
        case .drop:
            return .drop
        default:
            return nil
        }
    }
}

private extension TLSUnauthorizedPolicy {
    var swiftValue: UnauthorizedPolicy? {
        switch self {
        case .retain:
            return .retain
        case .drop:
            return .drop
        default:
            return nil
        }
    }
}

private extension TLSAddMode {
    var swiftValue: AddMode? {
        switch self {
        case .normal:
            return .normal
        case .immediate:
            return .immediate
        default:
            return nil
        }
    }
}

private extension BufferFullPolicy {
    var objcValue: TLSBufferFullPolicy {
        switch self {
        case .reject:
            return .reject
        case .block:
            return .block
        }
    }
}

private extension Compression {
    var objcValue: TLSCompression {
        switch self {
        case .disabled:
            return .disabled
        case .lz4:
            return .lz4
        }
    }
}

private extension Persistence {
    var objcValue: TLSPersistence {
        switch self {
        case .disabled:
            return .disabled
        case .memory:
            return .memory
        case .buffered:
            return .buffered
        case .sync:
            return .sync
        }
    }
}

private extension ExpiredLogPolicy {
    var objcValue: TLSExpiredLogPolicy {
        switch self {
        case .rewriteTimestamp:
            return .rewriteTimestamp
        case .drop:
            return .drop
        }
    }
}

private extension UnauthorizedPolicy {
    var objcValue: TLSUnauthorizedPolicy {
        switch self {
        case .retain:
            return .retain
        case .drop:
            return .drop
        }
    }
}

private extension SendResult.Status {
    var objcValue: TLSSendResultStatus {
        switch self {
        case .success:
            return .success
        case .failure:
            return .failure
        }
    }
}

// MARK: - Value objects

/// Objective-C credentials value object.
///
/// Properties are mutable for declarative setup. `TLSProducer.open` and
/// `updateCredentials` copy them synchronously at their call boundary; the
/// object does not promise safety for concurrent property mutation.
@objc(TLSCredentials)
@objcMembers
public final class TLSCredentials: NSObject {
    public var accessKeyID: String
    public var accessKeySecret: String
    public var securityToken: String?

    @objc(initWithAccessKeyID:accessKeySecret:securityToken:)
    public init(accessKeyID: String,
                accessKeySecret: String,
                securityToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.accessKeySecret = accessKeySecret
        self.securityToken = securityToken
        super.init()
    }

    internal func swiftValue() -> Credentials {
        Credentials(accessKeyID: accessKeyID,
                    accessKeySecret: accessKeySecret,
                    securityToken: securityToken)
    }

    /// Credentials never appear in object descriptions.
    public override var description: String {
        "TLSCredentials(<redacted>)"
    }

    @available(*, unavailable, message: "Use initWithAccessKeyID:accessKeySecret:securityToken:")
    public override init() {
        fatalError("TLSCredentials requires accessKeyID and accessKeySecret")
    }
}

/// Objective-C destination value object.
///
/// Properties are mutable for declarative setup. `TLSProducer.open` and
/// `updateDestination` copy them synchronously at their call boundary; the
/// object does not promise safety for concurrent property mutation.
@objc(TLSDestination)
@objcMembers
public final class TLSDestination: NSObject {
    public var endpoint: String
    public var region: String
    public var projectID: String
    public var topicID: String

    @objc(initWithEndpoint:region:projectID:topicID:)
    public init(endpoint: String,
                region: String,
                projectID: String,
                topicID: String) {
        self.endpoint = endpoint
        self.region = region
        self.projectID = projectID
        self.topicID = topicID
        super.init()
    }

    internal func swiftValue() -> Destination {
        Destination(endpoint: endpoint,
                     region: region,
                     projectID: projectID,
                     topicID: topicID)
    }

    /// Destination descriptions omit all caller-provided fields so they are
    /// safe to include in diagnostics by Objective-C clients.
    public override var description: String {
        "TLSDestination(<redacted>)"
    }

    @available(*, unavailable, message: "Use initWithEndpoint:region:projectID:topicID:")
    public override init() {
        fatalError("TLSDestination requires endpoint, region, projectID, and topicID")
    }
}

/// Objective-C log event value object.
///
/// `contents` is a Swift `[String: String]`, imported by Objective-C as an
/// `NSDictionary<NSString *, NSString *> *`. Values are intentionally kept
/// explicit strings; the facade never converts arbitrary NSNumber/NSObject
/// instances with `String(describing:)`.
/// Properties are mutable for declarative setup and are copied synchronously
/// by `addLog`; concurrent mutation is not promised to be safe.
@objc(TLSLogEvent)
@objcMembers
public final class TLSLogEvent: NSObject {
    /// Event timestamp. The Swift model derives epoch milliseconds and the
    /// nanosecond remainder from this same NSDate/Date value at admission.
    public var timestamp: Date {
        didSet { invalidateSwiftValue() }
    }
    public var hashKey: String? {
        didSet { invalidateSwiftValue() }
    }
    public var contents: [String: String] {
        didSet { invalidateSwiftValue() }
    }

    @nonobjc private let swiftValueLock = NSLock()
    @nonobjc private var cachedSwiftValue: LogEvent?

    @objc(initWithTimestamp:hashKey:contents:)
    public init(timestamp: Date = Date(),
                hashKey: String? = nil,
                contents: [String: String] = [:]) {
        self.timestamp = timestamp
        self.hashKey = hashKey
        self.contents = contents
        super.init()
    }

    internal func swiftValue() -> LogEvent {
        swiftValueLock.lock()
        defer { swiftValueLock.unlock() }
        if let cachedSwiftValue {
            return cachedSwiftValue
        }
        let values = contents.mapValues { LogValue.string($0) }
        let value = LogEvent(timestamp: timestamp, hashKey: hashKey, contents: values)
        cachedSwiftValue = value
        return value
    }

    // Protect lazy initialization for concurrent read-only admission. Public
    // field mutation must still be serialized by the caller.
    @nonobjc private func invalidateSwiftValue() {
        swiftValueLock.lock()
        defer { swiftValueLock.unlock() }
        cachedSwiftValue = nil
    }

    @nonobjc internal var hasCachedSwiftValue: Bool {
        swiftValueLock.lock()
        defer { swiftValueLock.unlock() }
        return cachedSwiftValue != nil
    }

    /// Log bodies are omitted from object descriptions.
    public override var description: String {
        "TLSLogEvent(<redacted>)"
    }

    @objc public override convenience init() {
        self.init(timestamp: Date(), hashKey: nil, contents: [:])
    }
}

// MARK: - Configuration

/// Objective-C configuration object.
///
/// The Swift configuration's nested batch/buffer/metadata structs are
/// flattened here so Objective-C callers only need Foundation scalar,
/// dictionary, queue, and URL-session types. The object is mutable until
/// `TLSProducer.open...` is called; that method synchronously copies every
/// field before starting its asynchronous Task. Concurrent mutation of this
/// NSObject is not promised to be safe.
@objc(TLSProducerConfiguration)
@objcMembers
public final class TLSProducerConfiguration: NSObject {
    // BatchConfiguration
    public var batchMaxLogCount: Int
    public var batchMaxRawBytes: Int
    public var batchLinger: TimeInterval

    // BufferConfiguration
    public var bufferMaxBytes: Int
    public var bufferFullPolicy: TLSBufferFullPolicy
    public var bufferBlockTimeout: TimeInterval

    // ProducerConfiguration scalar fields
    public var sendConcurrency: Int
    public var compression: TLSCompression
    public var persistence: TLSPersistence
    public var connectTimeout: TimeInterval
    public var requestTimeout: TimeInterval

    // ProducerMetadata
    public var metadataSource: String
    public var metadataFileName: String?
    public var metadataTags: [String: String]

    public var maxLogAge: TimeInterval
    public var expiredLogPolicy: TLSExpiredLogPolicy
    public var unauthorizedPolicy: TLSUnauthorizedPolicy
    public var callbackQueue: DispatchQueue
    public var urlSessionConfiguration: URLSessionConfiguration
    public var automaticLifecycleHandling: Bool
    public var producerID: String?
    public var destination: TLSDestination?

    public override init() {
        // Keep facade defaults derived from the canonical Swift model so a
        // future Swift default change cannot silently diverge from ObjC.
        guard let defaults = try? ProducerConfiguration() else {
            fatalError("ProducerConfiguration defaults must remain valid")
        }
        batchMaxLogCount = defaults.batch.maxLogCount
        batchMaxRawBytes = defaults.batch.maxRawBytes
        batchLinger = defaults.batch.linger
        bufferMaxBytes = defaults.buffer.maxBytes
        bufferFullPolicy = defaults.buffer.fullPolicy.objcValue
        bufferBlockTimeout = defaults.buffer.blockTimeout
        sendConcurrency = defaults.sendConcurrency
        compression = defaults.compression.objcValue
        persistence = defaults.persistence.objcValue
        connectTimeout = defaults.connectTimeout
        requestTimeout = defaults.requestTimeout
        metadataSource = defaults.metadata.source
        metadataFileName = defaults.metadata.fileName
        metadataTags = defaults.metadata.tags
        maxLogAge = defaults.maxLogAge
        expiredLogPolicy = defaults.expiredLogPolicy.objcValue
        unauthorizedPolicy = defaults.unauthorizedPolicy.objcValue
        callbackQueue = defaults.callbackQueue
        urlSessionConfiguration = defaults.urlSessionConfiguration
        automaticLifecycleHandling = defaults.automaticLifecycleHandling
        producerID = defaults.producerID
        destination = nil
        super.init()
    }

    /// Synchronously converts all mutable NSObject properties to Swift value
    /// models. The returned configuration owns a copied URL session config;
    /// no Objective-C object is read after the async Task starts.
    internal func swiftValue() throws -> ProducerConfiguration {
        guard let fullPolicy = bufferFullPolicy.swiftValue,
              let compression = compression.swiftValue,
              let persistence = persistence.swiftValue,
              let expiredPolicy = expiredLogPolicy.swiftValue,
              let unauthorizedPolicy = unauthorizedPolicy.swiftValue else {
            throw ProducerError.configuration("unsupported Objective-C enum value")
        }

        let swiftDestination = destination?.swiftValue()
        let batch = BatchConfiguration(
            maxLogCount: batchMaxLogCount,
            maxRawBytes: batchMaxRawBytes,
            linger: batchLinger)
        let buffer = BufferConfiguration(
            maxBytes: bufferMaxBytes,
            fullPolicy: fullPolicy,
            blockTimeout: bufferBlockTimeout)
        let metadata = ProducerMetadata(
            source: metadataSource,
            fileName: metadataFileName,
            tags: metadataTags)

        return try ProducerConfiguration(
            batch: batch,
            buffer: buffer,
            sendConcurrency: sendConcurrency,
            compression: compression,
            persistence: persistence,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            metadata: metadata,
            maxLogAge: maxLogAge,
            expiredLogPolicy: expiredPolicy,
            unauthorizedPolicy: unauthorizedPolicy,
            callbackQueue: callbackQueue,
            urlSessionConfiguration: urlSessionConfiguration,
            automaticLifecycleHandling: automaticLifecycleHandling,
            producerID: producerID,
            destination: swiftDestination)
    }
}

// MARK: - Send result

/// Immutable Objective-C terminal batch result.
@objc(TLSSendResult)
@objcMembers
public final class TLSSendResult: NSObject, @unchecked Sendable {
    public let status: TLSSendResultStatus
    public let rawBytes: Int
    public let compressedBytes: Int
    public let requestID: String?
    public let error: NSError?

    internal init(swiftValue: SendResult) {
        status = swiftValue.status.objcValue
        rawBytes = swiftValue.rawBytes
        compressedBytes = swiftValue.compressedBytes
        requestID = swiftValue.requestID
        error = swiftValue.error.map(TLSProducer.makeNSError)
        super.init()
    }

    /// Send-result objects contain no log bodies or credential material.
    public override var description: String {
        "TLSSendResult(status: \(status == .success ? "success" : "failure"), rawBytes: \(rawBytes), compressedBytes: \(compressedBytes))"
    }

    @available(*, unavailable, message: "TLSSendResult objects are delivered by TLSProducer")
    public override init() {
        fatalError("TLSSendResult objects are delivered by TLSProducer")
    }
}

// MARK: - Producer facade

/// Objective-C lifecycle and admission facade over the public Swift Producer.
@objc(TLSProducer)
@objcMembers
public final class TLSProducer: NSObject, @unchecked Sendable {
    /// Stable NSError domain for every facade completion/error-pointer error.
    public static let errorDomain = "com.volcengine.tls.producer.error"

    /// NSError userInfo key whose value is the stable ProducerError string.
    public static let errorCodeKey = "TLSProducerErrorCode"

    private let swiftProducer: Producer
    private let callbackQueue: DispatchQueue

    private init(swiftProducer: Producer, callbackQueue: DispatchQueue) {
        self.swiftProducer = swiftProducer
        self.callbackQueue = callbackQueue
        super.init()
    }

    /// Contract-test seam: wraps an already-created Swift Producer without
    /// exposing CoreAdapter or adding another production construction path.
    internal static func makeForTesting(
        swiftProducer: Producer,
        callbackQueue: DispatchQueue
    ) -> TLSProducer {
        TLSProducer(swiftProducer: swiftProducer, callbackQueue: callbackQueue)
    }

    /// Opens a producer asynchronously. Every configuration and credential
    /// field is copied before the asynchronous Task starts. Both completion
    /// and `onSendResult` are delivered on the configured callback queue.
    @objc(openWithConfiguration:credentials:onSendResult:completion:)
    public static func open(
        with configuration: TLSProducerConfiguration,
        credentials: TLSCredentials,
        onSendResult: (@Sendable (TLSSendResult) -> Void)? = nil,
        completion: @escaping @Sendable (TLSProducer?, NSError?) -> Void
    ) {
        // Capture the queue first so even a synchronous snapshot-validation
        // failure follows the callback-queue contract.
        let queue = configuration.callbackQueue
        let swiftConfiguration: ProducerConfiguration
        let swiftCredentials: Credentials
        do {
            swiftConfiguration = try configuration.swiftValue()
            swiftCredentials = credentials.swiftValue()
        } catch {
            let nsError = Self.makeNSError(error)
            queue.async {
                completion(nil, nsError)
            }
            return
        }

        // Only immutable/sendable value snapshots and callback blocks are
        // captured below. The mutable Objective-C objects are never touched
        // after this point.
        Task { @Sendable in
            do {
                let producer = try await Producer.open(
                    configuration: swiftConfiguration,
                    credentials: swiftCredentials,
                    onSendResult: { result in
                        guard let onSendResult else { return }
                        let objcResult = TLSSendResult(swiftValue: result)
                        // Producer guarantees delivery on the configured queue;
                        // preserve that ordering without adding another hop.
                        onSendResult(objcResult)
                    })
                let objcProducer = TLSProducer(
                    swiftProducer: producer,
                    callbackQueue: queue)
                queue.async {
                    completion(objcProducer, nil)
                }
            } catch {
                let nsError = Self.makeNSError(error)
                queue.async {
                    completion(nil, nsError)
                }
            }
        }
    }

    /// Convenience open when no send-result handler is needed.
    @objc(openWithConfiguration:credentials:completion:)
    public static func open(
        with configuration: TLSProducerConfiguration,
        credentials: TLSCredentials,
        completion: @escaping @Sendable (TLSProducer?, NSError?) -> Void
    ) {
        open(with: configuration,
             credentials: credentials,
             onSendResult: nil,
             completion: completion)
    }

    /// Closes asynchronously. Completion is called exactly once on the
    /// callback queue captured by the open snapshot.
    @objc(closeWithTimeout:completion:)
    public func close(
        withTimeout timeout: TimeInterval,
        completion: @escaping @Sendable (NSError?) -> Void
    ) {
        let producer = swiftProducer
        let queue = callbackQueue
        Task { @Sendable in
            do {
                try await producer.close(timeout: timeout)
                queue.async {
                    completion(nil)
                }
            } catch {
                let nsError = Self.makeNSError(error)
                queue.async {
                    completion(nsError)
                }
            }
        }
    }

    /// Synchronously admits one log and maps Swift throws to BOOL/NSError**.
    @objc(addLog:mode:error:)
    @discardableResult
    public func addLog(
        _ log: TLSLogEvent,
        mode: TLSAddMode,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        errorPointer?.pointee = nil
        guard let swiftMode = mode.swiftValue else {
            errorPointer?.pointee = Self.makeNSError(
                ProducerError.configuration("unsupported Objective-C enum value"))
            return false
        }
        do {
            // Convert the mutable NSObject synchronously at the call boundary.
            try swiftProducer.add(log.swiftValue(), mode: swiftMode)
            return true
        } catch {
            errorPointer?.pointee = Self.makeNSError(error)
            return false
        }
    }

    /// Synchronously admits one log in normal mode.
    @objc(addLog:error:)
    @discardableResult
    public func addLog(_ log: TLSLogEvent, error errorPointer: NSErrorPointer) -> Bool {
        addLog(log, mode: .normal, error: errorPointer)
    }

    /// Atomically replaces the credentials group.
    @objc(updateCredentials:error:)
    @discardableResult
    public func updateCredentials(
        _ credentials: TLSCredentials,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        errorPointer?.pointee = nil
        do {
            try swiftProducer.updateCredentials(credentials.swiftValue())
            return true
        } catch {
            errorPointer?.pointee = Self.makeNSError(error)
            return false
        }
    }

    /// Atomically replaces the destination.
    @objc(updateDestination:error:)
    @discardableResult
    public func updateDestination(
        _ destination: TLSDestination,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        errorPointer?.pointee = nil
        do {
            try swiftProducer.updateDestination(destination.swiftValue())
            return true
        } catch {
            errorPointer?.pointee = Self.makeNSError(error)
            return false
        }
    }

    /// Converts every current ProducerError case to a stable ObjC NSError.
    /// Associated text is intentionally not copied into userInfo or the
    /// localized description. Unknown Error values use code 0 and a generic
    /// description so arbitrary underlying text cannot escape this boundary.
    internal static func makeNSError(_ error: Error) -> NSError {
        guard let producerError = error as? ProducerError else {
            return NSError(
                domain: errorDomain,
                code: TLSProducerErrorCode.unknown.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey: "TLS producer operation failed.",
                    errorCodeKey: TLSProducerErrorCode.unknown.stableString,
                ])
        }

        let code = TLSProducerErrorCode(producerError: producerError)
        return NSError(
            domain: errorDomain,
            code: code.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: producerError.safeDescription,
                errorCodeKey: code.stableString,
            ])
    }

    @available(*, unavailable, message: "Use TLSProducer.openWithConfiguration:credentials:completion:")
    public override init() {
        fatalError("TLSProducer must be created by open")
    }
}

// MARK: - Error mapping helpers

private extension ProducerError {
    var safeDescription: String {
        switch self {
        case .configuration:
            return "TLS producer configuration is invalid."
        case .invalidLog:
            return "TLS log event is invalid."
        case .invalidState:
            return "TLS producer is not in a valid state for this operation."
        case .queueFull:
            return "TLS producer admission queue is full."
        case .bufferFull:
            return "TLS producer buffer is full."
        case .singleLogTooLarge:
            return "TLS log event exceeds the configured batch limit."
        case .persistence:
            return "TLS producer persistence failed."
        case .transport:
            return "TLS producer transport failed."
        case .service:
            return "TLS service request failed."
        case .auth:
            return "TLS service authorization failed."
        case .quota:
            return "TLS service quota was exceeded."
        case .timeout:
            return "TLS producer operation timed out."
        case .cancelled:
            return "TLS producer operation was cancelled."
        case .closed:
            return "TLS producer is closed."
        case .`internal`:
            return "TLS producer encountered an internal error."
        }
    }
}

private extension TLSProducerErrorCode {
    init(producerError: ProducerError) {
        switch producerError {
        case .configuration:
            self = .configuration
        case .invalidLog:
            self = .invalidLog
        case .invalidState:
            self = .invalidState
        case .queueFull:
            self = .queueFull
        case .bufferFull:
            self = .bufferFull
        case .singleLogTooLarge:
            self = .singleLogTooLarge
        case .persistence:
            self = .persistence
        case .transport:
            self = .transport
        case .service:
            self = .service
        case .auth:
            self = .auth
        case .quota:
            self = .quota
        case .timeout:
            self = .timeout
        case .cancelled:
            self = .cancelled
        case .closed:
            self = .closed
        case .`internal`:
            self = .internal
        }
    }

    /// The stable string is intentionally derived only from the fixed enum
    /// case, never from a caller-controlled error description.
    var stableString: String {
        switch self {
        case .unknown:
            return "unknown"
        case .configuration:
            return "configuration"
        case .invalidLog:
            return "invalidLog"
        case .invalidState:
            return "invalidState"
        case .queueFull:
            return "queueFull"
        case .bufferFull:
            return "bufferFull"
        case .singleLogTooLarge:
            return "singleLogTooLarge"
        case .persistence:
            return "persistence"
        case .transport:
            return "transport"
        case .service:
            return "service"
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
        case .internal:
            return "internal"
        }
    }
}
