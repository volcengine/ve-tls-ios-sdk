//
//  ProducerConfiguration.swift
//  VolcengineTLSProducer
//
//  Worker A — Swift public value model.
//

import Foundation

/// Policy when the in-memory buffer is full.
public enum BufferFullPolicy: Equatable, Sendable {
    /// Fail fast: `add` throws `.bufferFull`. Never blocks the caller —
    /// safe on the main thread.
    case reject
    /// Block the calling thread until space is available. Must not be used
    /// on the main thread.
    case block
}

/// Compression algorithm for outgoing batches.
public enum Compression: Equatable, Sendable {
    case disabled
    case lz4
}

/// Persistence mode for admitted logs.
public enum Persistence: Equatable, Sendable {
    /// No persistence; logs live in memory only.
    case disabled
    /// In-memory durability class (explicit alias of `.disabled` semantics).
    /// This mode does not create a directory and does not require a
    /// `producerID`.
    case memory
    /// Buffered WAL: writes are buffered; crash/power-loss boundaries apply.
    case buffered
    /// Sync WAL: every admission waits for the WAL sync. Must not be used
    /// on the main thread.
    case sync
}

/// Policy for logs older than `maxLogAge`.
public enum ExpiredLogPolicy: Equatable, Sendable {
    /// Rewrite the timestamp to the current time before sending.
    case rewriteTimestamp
    /// Drop the expired log.
    case drop
}

/// Policy for 401/403 (unauthorized) responses.
public enum UnauthorizedPolicy: Equatable, Sendable {
    /// Retain the data and suspend delivery until credentials are updated.
    case retain
    /// Drop the data after an explicit unauthorized response.
    case drop
}

/// Batching thresholds.
public struct BatchConfiguration: Equatable, Sendable {
    /// Max logs per batch. Default 1024 (SLS iOS wrapper).
    public var maxLogCount: Int
    /// Max uncompressed bytes per batch. Default 1 MiB (SLS iOS wrapper).
    public var maxRawBytes: Int
    /// Max wait before sealing a non-empty batch. Default 3 s (SLS iOS wrapper).
    public var linger: TimeInterval

    public init(maxLogCount: Int = 1024,
                maxRawBytes: Int = 1024 * 1024,
                linger: TimeInterval = 3) {
        self.maxLogCount = maxLogCount
        self.maxRawBytes = maxRawBytes
        self.linger = linger
    }
}

/// In-memory buffer limits.
public struct BufferConfiguration: Equatable, Sendable {
    /// Max buffered bytes across all pending batches. Default 64 MiB (SLS),
    /// maximum 256 MiB per producer on iOS.
    public var maxBytes: Int
    /// Behavior when the buffer is full. Default `.reject` (SLS fail-fast).
    public var fullPolicy: BufferFullPolicy

    /// Maximum time a `.block` admission may wait for buffer space. The
    /// timeout is bounded and expressed in whole milliseconds when passed to
    /// the C Core. It is ignored for `.reject`.
    public var blockTimeout: TimeInterval

    public init(maxBytes: Int = 64 * 1024 * 1024,
                fullPolicy: BufferFullPolicy = .reject,
                blockTimeout: TimeInterval = 1) {
        self.maxBytes = maxBytes
        self.fullPolicy = fullPolicy
        self.blockTimeout = blockTimeout
    }
}

/// Build-time configuration for a `Producer`. Frozen at `open` time.
///
/// All defaults align with the SLS iOS wrapper / SLS C defaults (see the
/// Beta design §5.5 table). The initializer validates all locally complete
/// fields, and `Producer.open` revalidates an immutable snapshot including
/// the destination and credentials. Validation throws the first applicable
/// public `ProducerError`.
/// The value is `Sendable`; callers may pass a copied configuration across
/// tasks. As with any mutable value, do not concurrently mutate the same
/// variable while another task is reading it for `Producer.open`.
public struct ProducerConfiguration: Sendable {

    /// Public-contract upper bounds for one batch. These are stricter than
    /// the underlying C integer representation so callers cannot configure a
    /// value that violates the TLS service admission contract.
    internal static let maxBatchLogCount = 10_000
    internal static let maxBatchRawBytes = 10 * 1024 * 1024
    internal static let maxBufferBytes = 256 * 1024 * 1024
    internal static let maxSendConcurrency = 8

    public var batch: BatchConfiguration
    public var buffer: BufferConfiguration
    /// Number of Core sender threads. Valid range: 1...8.
    public var sendConcurrency: Int
    public var compression: Compression
    public var persistence: Persistence
    public var connectTimeout: TimeInterval
    public var requestTimeout: TimeInterval
    public var metadata: ProducerMetadata
    public var maxLogAge: TimeInterval
    public var expiredLogPolicy: ExpiredLogPolicy
    public var unauthorizedPolicy: UnauthorizedPolicy

    /// Serial utility queue used to deliver `onSendResult` handlers.
    /// Default: SDK-owned queue labeled `com.volcengine.tls.producer.callback`.
    public var callbackQueue: DispatchQueue

    /// URL session configuration. Default is `.ephemeral` (no on-disk
    /// cache/cookie/credential store). The initializer defensively clears
    /// `urlCache`, `httpCookieStorage`, `urlCredentialStorage`, and disables
    /// automatic cookies even for caller-supplied configurations.
    public var urlSessionConfiguration: URLSessionConfiguration

    /// Whether the SDK manages app lifecycle notifications (background/fetch
    /// flushing). Default: `true` in app processes, `false` in app
    /// extensions (runtime detection). Pass an explicit value to override.
    public var automaticLifecycleHandling: Bool

    /// Optional stable producer identifier. Required when `persistence` is
    /// `.buffered` or `.sync`. Allowed characters: `[A-Za-z0-9._-]`, max 64
    /// UTF-8 bytes.
    public var producerID: String?

    /// The send target (endpoint/region/project/topic). Required by public
    /// `Producer.open`; the internal injected-adapter entry point may omit it
    /// for tests. Use `updateDestination` to change it after `open`.
    public var destination: Destination?

    public init(
        batch: BatchConfiguration = BatchConfiguration(),
        buffer: BufferConfiguration = BufferConfiguration(),
        sendConcurrency: Int = 1,
        compression: Compression = .lz4,
        persistence: Persistence = .disabled,
        connectTimeout: TimeInterval = 10,
        requestTimeout: TimeInterval = 15,
        metadata: ProducerMetadata = ProducerMetadata(),
        maxLogAge: TimeInterval = 7 * 24 * 60 * 60,
        expiredLogPolicy: ExpiredLogPolicy = .rewriteTimestamp,
        unauthorizedPolicy: UnauthorizedPolicy = .retain,
        callbackQueue: DispatchQueue = DispatchQueue(
            label: "com.volcengine.tls.producer.callback",
            qos: .utility),
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral,
        automaticLifecycleHandling: Bool = ProducerConfiguration.defaultAutomaticLifecycleHandling(),
        producerID: String? = nil,
        destination: Destination? = nil
    ) throws {
        // --- validation -------------------------------------------------
        guard batch.maxLogCount > 0 else {
            throw ProducerError.configuration("batch.maxLogCount must be greater than 0")
        }
        guard batch.maxLogCount <= Self.maxBatchLogCount else {
            throw ProducerError.configuration(
                "batch.maxLogCount must be at most \(Self.maxBatchLogCount)")
        }
        guard batch.maxRawBytes > 0 else {
            throw ProducerError.configuration("batch.maxRawBytes must be greater than 0")
        }
        guard batch.maxRawBytes <= Self.maxBatchRawBytes else {
            throw ProducerError.configuration(
                "batch.maxRawBytes must be at most \(Self.maxBatchRawBytes) bytes")
        }
        try Self.validateMilliseconds(
            batch.linger,
            name: "batch.linger",
            allowZero: true)
        guard buffer.maxBytes > 0 else {
            throw ProducerError.configuration("buffer.maxBytes must be greater than 0")
        }
        guard buffer.maxBytes <= Self.maxBufferBytes else {
            throw ProducerError.configuration(
                "buffer.maxBytes must be at most \(Self.maxBufferBytes) bytes")
        }
        if buffer.fullPolicy == .block {
            try Self.validateMilliseconds(
                buffer.blockTimeout,
                name: "buffer.blockTimeout",
                allowZero: false)
        } else if !buffer.blockTimeout.isFinite {
            throw ProducerError.configuration("buffer.blockTimeout must be finite")
        }
        guard sendConcurrency > 0 else {
            throw ProducerError.configuration("sendConcurrency must be greater than 0")
        }
        guard sendConcurrency <= Self.maxSendConcurrency else {
            throw ProducerError.configuration(
                "sendConcurrency must be at most \(Self.maxSendConcurrency)")
        }
        try Self.validateMilliseconds(
            connectTimeout,
            name: "connectTimeout",
            allowZero: false)
        try Self.validateMilliseconds(
            requestTimeout,
            name: "requestTimeout",
            allowZero: false)
        try metadata.validate()
        try Self.validateWholeSeconds(maxLogAge, name: "maxLogAge")

        if let producerID = producerID {
            try Self.validateProducerID(producerID)
        }

        if (persistence == .buffered || persistence == .sync) && producerID == nil {
            throw ProducerError.configuration(
                "producerID is required when persistence is .buffered or .sync")
        }

        // --- normalization ----------------------------------------------
        // Copy before sanitizing: the caller's instance must not be mutated
        // (Beta design §8.2 — configuration is copied before the session is
        // built; the session configuration is not hot-updated afterwards).
        guard let sanitizedSessionConfiguration = urlSessionConfiguration.copy()
            as? URLSessionConfiguration else {
            throw ProducerError.configuration(
                "urlSessionConfiguration could not be copied")
        }
        // Guarantee no on-disk caches/stores regardless of caller input.
        sanitizedSessionConfiguration.urlCache = nil
        sanitizedSessionConfiguration.httpCookieStorage = nil
        sanitizedSessionConfiguration.urlCredentialStorage = nil
        sanitizedSessionConfiguration.httpShouldSetCookies = false

        self.batch = batch
        self.buffer = buffer
        self.sendConcurrency = sendConcurrency
        self.compression = compression
        self.persistence = persistence
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.metadata = metadata
        self.maxLogAge = maxLogAge
        self.expiredLogPolicy = expiredLogPolicy
        self.unauthorizedPolicy = unauthorizedPolicy
        self.callbackQueue = callbackQueue
        self.urlSessionConfiguration = sanitizedSessionConfiguration
        self.automaticLifecycleHandling = automaticLifecycleHandling
        self.producerID = producerID
        self.destination = destination
    }

    /// Runtime detection: app extensions carry an `NSExtension` key in their
    /// Info.plist. No UIKit dependency.
    public static func defaultAutomaticLifecycleHandling() -> Bool {
        return Bundle.main.infoDictionary?["NSExtension"] == nil
    }

    // MARK: - Open-time validation

    /// Re-validates mutable public fields at the open boundary and returns a
    /// defensive copy. The public initializer is intentionally source
    /// compatible and cannot prevent callers from mutating `public var`
    /// fields after construction, so this check must run immediately before
    /// any adapter or network work.
    internal func validatedForOpen(requireDestination: Bool) throws -> ProducerConfiguration {
        guard batch.maxLogCount > 0 else {
            throw ProducerError.configuration("batch.maxLogCount must be greater than 0")
        }
        guard batch.maxLogCount <= Self.maxBatchLogCount else {
            throw ProducerError.configuration(
                "batch.maxLogCount must be at most \(Self.maxBatchLogCount)")
        }
        guard batch.maxRawBytes > 0 else {
            throw ProducerError.configuration("batch.maxRawBytes must be greater than 0")
        }
        guard batch.maxRawBytes <= Self.maxBatchRawBytes else {
            throw ProducerError.configuration(
                "batch.maxRawBytes must be at most \(Self.maxBatchRawBytes) bytes")
        }
        try Self.validateMilliseconds(batch.linger, name: "batch.linger", allowZero: true)

        guard buffer.maxBytes > 0 else {
            throw ProducerError.configuration("buffer.maxBytes must be greater than 0")
        }
        guard buffer.maxBytes <= Self.maxBufferBytes else {
            throw ProducerError.configuration(
                "buffer.maxBytes must be at most \(Self.maxBufferBytes) bytes")
        }
        if buffer.fullPolicy == .block {
            try Self.validateMilliseconds(
                buffer.blockTimeout,
                name: "buffer.blockTimeout",
                allowZero: false)
        } else if !buffer.blockTimeout.isFinite {
            throw ProducerError.configuration("buffer.blockTimeout must be finite")
        }

        guard sendConcurrency > 0 else {
            throw ProducerError.configuration("sendConcurrency must be greater than 0")
        }
        guard sendConcurrency <= Self.maxSendConcurrency else {
            throw ProducerError.configuration(
                "sendConcurrency must be at most \(Self.maxSendConcurrency)")
        }
        try Self.validateMilliseconds(connectTimeout, name: "connectTimeout", allowZero: false)
        try Self.validateMilliseconds(requestTimeout, name: "requestTimeout", allowZero: false)
        try metadata.validate()
        try Self.validateWholeSeconds(maxLogAge, name: "maxLogAge")

        if let producerID = producerID {
            try Self.validateProducerID(producerID)
        }
        if (persistence == .buffered || persistence == .sync) && producerID == nil {
            throw ProducerError.configuration(
                "producerID is required when persistence is .buffered or .sync")
        }

        if let destination = destination {
            try destination.validate()
        } else if requireDestination {
            throw ProducerError.configuration("destination is required")
        }

        guard let sanitizedSessionConfiguration = urlSessionConfiguration.copy()
            as? URLSessionConfiguration else {
            throw ProducerError.configuration(
                "urlSessionConfiguration could not be copied")
        }
        Self.sanitize(sanitizedSessionConfiguration)

        var validated = self
        validated.urlSessionConfiguration = sanitizedSessionConfiguration
        return validated
    }

    /// Validates a timeout that is converted to the C Core's int32
    /// millisecond representation. `allowZero` is used for close and linger;
    /// send/connect/block timeouts require at least one millisecond.
    internal static func validateMilliseconds(
        _ value: TimeInterval,
        name: String,
        allowZero: Bool
    ) throws {
        guard value.isFinite else {
            throw ProducerError.configuration("\(name) must be finite")
        }
        guard allowZero ? value >= 0 : value > 0 else {
            let bound = allowZero ? "greater than or equal to 0" : "greater than 0"
            throw ProducerError.configuration("\(name) must be \(bound)")
        }

        let milliseconds = value * 1_000
        guard milliseconds.isFinite else {
            throw ProducerError.configuration("\(name) exceeds the C Core millisecond range")
        }
        if !allowZero && milliseconds < 1 {
            throw ProducerError.configuration("\(name) must be at least 1 millisecond")
        }
        guard milliseconds <= Double(Int32.max) else {
            throw ProducerError.configuration(
                "\(name) exceeds the C Core Int32 millisecond range")
        }
        // The bridge currently casts to int32_t rather than explicitly
        // rounding. Reject a fractional millisecond so it cannot silently
        // become zero or a different timeout.
        guard milliseconds.rounded() == milliseconds else {
            throw ProducerError.configuration(
                "\(name) must be representable in whole milliseconds")
        }
    }

    /// `maxLogAge` is passed as whole seconds to the ObjC bridge and then as
    /// int64 milliseconds to the C Core. Reject fractional seconds and values
    /// that would overflow either conversion.
    private static func validateWholeSeconds(
        _ value: TimeInterval,
        name: String
    ) throws {
        guard value.isFinite else {
            throw ProducerError.configuration("\(name) must be finite")
        }
        guard value > 0 else {
            throw ProducerError.configuration("\(name) must be greater than 0")
        }
        guard value.rounded() == value else {
            throw ProducerError.configuration("\(name) must be representable in whole seconds")
        }
        guard value <= Double(Int64.max) / 1_000 else {
            throw ProducerError.configuration(
                "\(name) exceeds the C Core integer millisecond range")
        }
    }

    private static func validateProducerID(_ producerID: String) throws {
        guard !producerID.isEmpty else {
            throw ProducerError.configuration("producerID must not be empty")
        }
        guard producerID != "." && producerID != ".." else {
            throw ProducerError.configuration("producerID must not be \".\" or \"..\"")
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard producerID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ProducerError.configuration(
                "producerID may only contain [A-Za-z0-9._-]")
        }
        guard producerID.utf8.count <= 64 else {
            throw ProducerError.configuration("producerID must be at most 64 UTF-8 bytes")
        }
    }

    private static func sanitize(_ configuration: URLSessionConfiguration) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
    }
}

/// Immutable snapshot of a `ProducerConfiguration`, taken once at `open`.
/// Internal: the public contract is that configuration is frozen after open.
internal struct ConfigurationSnapshot {
    let batch: BatchConfiguration
    let buffer: BufferConfiguration
    let sendConcurrency: Int
    let compression: Compression
    let persistence: Persistence
    let connectTimeout: TimeInterval
    let requestTimeout: TimeInterval
    let metadata: ProducerMetadata
    let maxLogAge: TimeInterval
    let expiredLogPolicy: ExpiredLogPolicy
    let unauthorizedPolicy: UnauthorizedPolicy
    let callbackQueue: DispatchQueue
    let urlSessionConfiguration: URLSessionConfiguration
    let automaticLifecycleHandling: Bool
    let producerID: String?
    let destination: Destination?

    init(_ configuration: ProducerConfiguration) {
        self.batch = configuration.batch
        self.buffer = configuration.buffer
        self.sendConcurrency = configuration.sendConcurrency
        self.compression = configuration.compression
        self.persistence = configuration.persistence
        self.connectTimeout = configuration.connectTimeout
        self.requestTimeout = configuration.requestTimeout
        self.metadata = configuration.metadata
        self.maxLogAge = configuration.maxLogAge
        self.expiredLogPolicy = configuration.expiredLogPolicy
        self.unauthorizedPolicy = configuration.unauthorizedPolicy
        self.callbackQueue = configuration.callbackQueue
        self.urlSessionConfiguration = configuration.urlSessionConfiguration
        self.automaticLifecycleHandling = configuration.automaticLifecycleHandling
        self.producerID = configuration.producerID
        self.destination = configuration.destination
    }
}
