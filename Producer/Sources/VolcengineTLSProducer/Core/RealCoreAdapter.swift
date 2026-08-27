//
//  RealCoreAdapter.swift
//  VolcengineTLSProducer/Core
//
//  Swift wrapper around the ObjC TLSRealCoreAdapter (C Core v0.3.1).
//  Conforms to the CoreAdapter seam protocol.
//
//  PROVISIONAL — the CoreAdapter seam is marked PROVISIONAL (not a public API
//  contract). This implementation replaces the BundledCoreAdapter as the
//  default for Producer.open, providing real persistence/retry/batching via
//  the vendored C Core.
//

import Foundation
import TLSProducerBridge

/// CoreAdapter backed by the real C Core (ve-tls-c-sdk v0.3.1).
///
/// Provides persistent WAL, retry, batching, LZ4 compression, and signing
/// via the C Core. The C Core creates its own sender/packer threads; this
/// adapter is a thin Swift↔C bridge.
internal final class RealCoreAdapter: CoreAdapter {

    var onSendResult: (@Sendable (SendResult) -> Void)?

    private let adapter: TLSRealCoreAdapter
    private let lock = NSLock()
    private var closed = false

    init(configuration: ProducerConfiguration, credentials: Credentials) throws {
        let dest = configuration.destination
        let persistentDir: String? = {
            guard configuration.persistence != .disabled,
                  let producerID = configuration.producerID else { return nil }
            guard let url = try? TLSProducerDirectory.defaultDirectoryURL(forProducerID: producerID) else { return nil }
            return url.path
        }()

        // The ObjC init is imported as throwing (nullable + NSError**).
        adapter = try TLSRealCoreAdapter(
            endpoint: dest?.endpoint ?? "",
            region: dest?.region ?? "",
            projectID: dest?.projectID ?? "",
            topicID: dest?.topicID ?? "",
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
            persistenceEnabled: configuration.persistence != .disabled,
            persistentDirectory: persistentDir,
            maxLogAgeSeconds: Int(configuration.maxLogAge),
            expiredLogPolicy: configuration.expiredLogPolicy == .drop ? 1 : 0,
            authFailurePolicy: configuration.unauthorizedPolicy == .drop ? 1 : 0,
            callbackQueue: configuration.callbackQueue)

        // Bridge the C Core callback to Swift SendResult
        adapter.onSendResult = { [weak self] result, rawBytes, compressedBytes, requestID, errorMessage, _, _ in
            guard let self = self else { return }
            let status: SendResult.Status = (result == 0) ? .success : .failure
            let error: ProducerError? = {
                if result == 0 { return nil }
                if let msg = errorMessage {
                    return .transport(msg)
                }
                return .transport("send failed (result=\(result))")
            }()
            let sendResult = SendResult(
                status: status,
                rawBytes: Int(rawBytes),
                compressedBytes: Int(compressedBytes),
                requestID: requestID,
                error: error)
            self.onSendResult?(sendResult)
        }
    }

    func open(configuration: ProducerConfiguration, credentials: Credentials) throws {
        // The C Core producer is created in init; open is a no-op.
    }

    func add(_ event: LogEvent, mode: AddMode) throws {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            throw ProducerError.closed
        }

        // Convert LogEvent contents to string key-value pairs
        var contents: [String: String] = [:]
        for (key, value) in event.contents {
            contents[key] = try value.encodedString()
        }

        let timestampMs = Int64(event.timestamp.timeIntervalSince1970 * 1000)
        try adapter.addLog(
            withTimestamp: timestampMs,
            hashKey: event.hashKey,
            contents: contents,
            flush: (mode == .immediate))
    }

    func updateCredentials(_ credentials: Credentials) throws {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            throw ProducerError.closed
        }
        try adapter.updateCredentials(
            credentials.accessKeyID,
            accessKeySecret: credentials.accessKeySecret,
            securityToken: credentials.securityToken)
    }

    func updateDestination(_ destination: Destination) throws {
        try destination.validate()
        lock.lock()
        defer { lock.unlock() }
        if closed {
            throw ProducerError.closed
        }
        try adapter.updateDestination(
            destination.endpoint,
            region: destination.region,
            topicID: destination.topicID)
    }

    func close(timeout: TimeInterval) async {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        adapter.close(withTimeout: timeout)
    }
}
