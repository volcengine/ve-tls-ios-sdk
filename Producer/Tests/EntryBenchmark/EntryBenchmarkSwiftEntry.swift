//
// EntryBenchmarkSwiftEntry.swift
// Swift entry: direct Producer.add calls.
//

import Foundation
import VolcengineTLSProducer

/// Swift's real public Producer entry used by the shared ObjC scheduler.
/// The class is ObjC-visible only so the mixed-language main can select it by
/// launch argument; the measured operation remains the direct Swift API call.
@objc(EBSwiftEntry)
final class EBSwiftEntry: NSObject, EBBenchmarkEntry {

    private let payload: EBBenchmarkPayload
    private let options: EBBenchmarkOptions
    private let event: LogEvent
    private var producer: Producer?
    @objc var terminalResultHandler: EBTerminalResultHandler?

    @objc(initWithPayload:options:)
    init(payload: EBBenchmarkPayload, options: EBBenchmarkOptions) {
        self.payload = payload
        self.options = options
        self.event = LogEvent(
            timestamp: payload.timestamp,
            contents: payload.fields.mapValues { LogValue.string($0) })
        super.init()
    }

    func startOpening() async throws {
        let configuration = try makeConfiguration()
        let credentials = Credentials(
            accessKeyID: "entry-benchmark-ak",
            // Requests are intercepted by the benchmark URLProtocol.
            accessKeySecret: UUID().uuidString)
        let callback: @Sendable (SendResult) -> Void = { [weak self] result in
            self?.terminalResultHandler?(
                result.status == .success,
                UInt(max(0, result.rawBytes)),
                UInt(max(0, result.compressedBytes)))
        }
        producer = try await Producer.open(
            configuration: configuration,
            credentials: credentials,
            onSendResult: callback)
    }

    func admitOne() -> EBAddOutcome {
        guard let producer else {
            return EBAddOutcome.rejectedOutcome(withErrorCode: "notOpen", latency: 0)
        }

        // Keep the timing inside the entry implementation so the dynamic
        // ObjC scheduler call is not part of Swift's add latency. The same
        // monotonic clock and pool boundary are used by the ObjC entry.
        return autoreleasepool {
            let begin = EBMonotonicSeconds()
            do {
                try producer.add(event, mode: .normal)
                let end = EBMonotonicSeconds()
                return EBAddOutcome.acceptedOutcome(withLatency: max(0, end - begin))
            } catch let error as ProducerError {
                let end = EBMonotonicSeconds()
                return EBAddOutcome.rejectedOutcome(
                    withErrorCode: error.errorCode,
                    latency: max(0, end - begin))
            } catch {
                let end = EBMonotonicSeconds()
                return EBAddOutcome.rejectedOutcome(
                    withErrorCode: "unknown",
                    latency: max(0, end - begin))
            }
        }
    }

    func startClosing(withTimeout timeout: TimeInterval,
                      completion: @escaping @Sendable (Error?) -> Void) {
        guard let producer else {
            completion(nil)
            return
        }
        Task { [weak self] in
            do {
                try await producer.close(timeout: timeout)
                self?.producer = nil
                completion(nil)
            } catch {
                completion(error as NSError)
            }
        }
    }

    private func makeConfiguration() throws -> ProducerConfiguration {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EBImmediateURLProtocol.self]
        let persistence: Persistence = options.persistence == "buffered"
            ? .buffered
            : .memory
        let producerID: String? = persistence == .buffered
            ? "entry-benchmark-swift-\(options.runID)"
            : nil
        let destination = Destination(
            endpoint: "https://entry-benchmark.invalid",
            region: "cn-beijing",
            projectID: "entry-benchmark-project",
            topicID: "entry-benchmark-topic")
        return try ProducerConfiguration(
            batch: BatchConfiguration(
                maxLogCount: Int(options.batchMaxLogCount),
                maxRawBytes: Int(options.batchMaxRawBytes),
                linger: options.batchLinger),
            buffer: BufferConfiguration(
                maxBytes: Int(options.bufferMaxBytes),
                fullPolicy: .reject,
                blockTimeout: options.bufferBlockTimeout),
            sendConcurrency: Int(options.sendConcurrency),
            compression: .lz4,
            persistence: persistence,
            connectTimeout: options.connectTimeout,
            requestTimeout: options.requestTimeout,
            metadata: ProducerMetadata(source: "entry-benchmark"),
            maxLogAge: 7 * 24 * 60 * 60,
            expiredLogPolicy: .rewriteTimestamp,
            unauthorizedPolicy: .retain,
            callbackQueue: options.callbackQueue,
            urlSessionConfiguration: sessionConfiguration,
            automaticLifecycleHandling: false,
            producerID: producerID,
            destination: destination)
    }
}
