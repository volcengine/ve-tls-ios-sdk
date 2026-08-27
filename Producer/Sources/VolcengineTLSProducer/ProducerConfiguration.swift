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
    /// NOTE: like every non-`.disabled` mode, it still requires a
    /// `producerID` so the directory identity exists when a real Core lands.
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
    /// Max buffered bytes across all pending batches. Default 64 MiB (SLS).
    public var maxBytes: Int
    /// Behavior when the buffer is full. Default `.reject` (SLS fail-fast).
    public var fullPolicy: BufferFullPolicy

    public init(maxBytes: Int = 64 * 1024 * 1024,
                fullPolicy: BufferFullPolicy = .reject) {
        self.maxBytes = maxBytes
        self.fullPolicy = fullPolicy
    }
}

/// Build-time configuration for a `Producer`. Frozen at `open` time.
///
/// All defaults align with the SLS iOS wrapper / SLS C defaults (see the
/// Beta design §5.5 table). The initializer validates every parameter and
/// throws `ProducerError.configuration` on the first violation.
public struct ProducerConfiguration {

    public var batch: BatchConfiguration
    public var buffer: BufferConfiguration
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

    /// Optional stable producer identifier. Required when `persistence !=
    /// .disabled`. Allowed characters: `[A-Za-z0-9._-]`, max 64 UTF-8 bytes.
    public var producerID: String?

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
        producerID: String? = nil
    ) throws {
        // --- validation -------------------------------------------------
        guard batch.maxLogCount > 0 else {
            throw ProducerError.configuration("batch.maxLogCount must be greater than 0")
        }
        guard batch.maxRawBytes > 0 else {
            throw ProducerError.configuration("batch.maxRawBytes must be greater than 0")
        }
        guard batch.linger >= 0 else {
            throw ProducerError.configuration("batch.linger must be greater than or equal to 0")
        }
        guard buffer.maxBytes > 0 else {
            throw ProducerError.configuration("buffer.maxBytes must be greater than 0")
        }
        guard sendConcurrency > 0 else {
            throw ProducerError.configuration("sendConcurrency must be greater than 0")
        }
        guard connectTimeout > 0 else {
            throw ProducerError.configuration("connectTimeout must be greater than 0")
        }
        guard requestTimeout > 0 else {
            throw ProducerError.configuration("requestTimeout must be greater than 0")
        }
        guard !metadata.source.isEmpty else {
            throw ProducerError.configuration("metadata.source must not be empty")
        }
        guard maxLogAge > 0 else {
            throw ProducerError.configuration("maxLogAge must be greater than 0")
        }

        if let producerID = producerID {
            guard !producerID.isEmpty else {
                throw ProducerError.configuration("producerID must not be empty")
            }
            let allowed = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard producerID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw ProducerError.configuration(
                    "producerID may only contain [A-Za-z0-9._-]")
            }
            guard producerID.utf8.count <= 64 else {
                throw ProducerError.configuration("producerID must be at most 64 UTF-8 bytes")
            }
        }

        if persistence != .disabled && producerID == nil {
            throw ProducerError.configuration(
                "producerID is required when persistence is not .disabled")
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
    }

    /// Runtime detection: app extensions carry an `NSExtension` key in their
    /// Info.plist. No UIKit dependency.
    public static func defaultAutomaticLifecycleHandling() -> Bool {
        return Bundle.main.infoDictionary?["NSExtension"] == nil
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
    }
}
