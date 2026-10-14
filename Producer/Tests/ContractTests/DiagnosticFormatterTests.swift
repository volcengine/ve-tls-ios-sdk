import Foundation
import XCTest
@testable import VolcengineTLSProducer

final class DiagnosticFormatterTests: XCTestCase {
    func testSchemaUsesNullForUnknownFieldsAndMillisecondsForDurations() throws {
        var details = ProducerDiagnosticDetails()
        details.timeMs = 1_793_000_000_123
        details.sequence = 12
        details.sdkVersion = "2.0.2"
        details.producerInstanceID = "instance"
        details.producerID = "p"
        details.topicID = "t"
        details.endpointHost = "logs.example.com"
        details.deliveryElapsedMs = 1250
        details.retryDelayMs = 300
        details.httpCode = 0
        details.requestID = "request-123"
        details.retryable = false
        details.disposition = "retained_wal"
        details.batchCount = 16
        details.batchRawBytes = 2048
        details.lingerMs = 3000
        details.requestTimeoutMs = 90_000
        details.addAttemptedTotal = 3
        details.addAcceptedTotal = 2
        details.coreRequestsTotal = 1
        details.fieldsOmitted = false

        let message = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(
                kind: .attemptFinished,
                reason: .nonRetryable,
                elapsed: 1.25,
                retryDelay: 0.3),
            context: details))
        let data = try XCTUnwrap(message.data(using: .utf8))
        XCTAssertLessThanOrEqual(data.count, DiagnosticFormatter.maxUTF8Bytes)
        XCTAssertFalse(message.contains("\n"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual(json["event"] as? String, "attempt_finished")
        XCTAssertEqual(json["level"] as? Int, ProducerDiagnosticLogLevel.warning.rawValue)
        XCTAssertEqual(json["time_ms"] as? Int, 1_793_000_000_123)
        XCTAssertEqual(json["sequence"] as? Int, 12)
        XCTAssertEqual(json["sdk_version"] as? String, "2.0.2")
        XCTAssertEqual(json["delivery_elapsed_ms"] as? Int, 1250)
        XCTAssertEqual(json["retry_delay_ms"] as? Int, 300)
        XCTAssertEqual(json["http_code"] as? Int, 0)
        XCTAssertEqual(json["batch_count"] as? Int, 16)
        XCTAssertEqual(json["request_timeout_ms"] as? Int, 90_000)
        XCTAssertEqual(json["add_accepted_total"] as? Int, 2)
        XCTAssertTrue(json["underlying_error_domain"] is NSNull)
        XCTAssertTrue(json["dns_ms"] is NSNull)
    }

    func testNonBatchLegacyDefaultsDoNotInventRetryOrTransportFields() throws {
        let message = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(kind: .opened)))
        let json = try XCTUnwrap(Self.object(message))
        XCTAssertTrue(json["batch_start_id"] is NSNull)
        XCTAssertTrue(json["http_code"] is NSNull)
        XCTAssertTrue(json["transport_code"] is NSNull)
        XCTAssertTrue(json["retryable"] is NSNull)

        let batch = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(
                kind: .attemptFinished,
                startID: 10,
                endID: 12,
                attemptCount: 1,
                cycleAttemptCount: 1,
                logCount: 3,
                rawBytes: 30,
                compressedBytes: 20,
                httpCode: 0,
                transportCode: 2103,
                retryable: true)))
        let batchJSON = try XCTUnwrap(Self.object(batch))
        XCTAssertEqual(batchJSON["batch_start_id"] as? Int, 10)
        XCTAssertEqual(batchJSON["transport_code"] as? Int, 2103)
        XCTAssertEqual(batchJSON["retryable"] as? Bool, true)
    }

    func testNewCoreObservationEventsDoNotFallbackToLegacyDefaults() throws {
        let sealed = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(kind: .batchSealed, retryable: false)))
        let started = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(kind: .attemptStarted, retryable: false)))
        for message in [sealed, started] {
            let json = try XCTUnwrap(Self.object(message))
            XCTAssertTrue(json["batch_start_id"] is NSNull)
            XCTAssertTrue(json["http_code"] is NSNull)
            XCTAssertTrue(json["transport_code"] is NSNull)
            XCTAssertTrue(json["retryable"] is NSNull)
        }
    }

    func testKindAndLevelValuesRemainStable() {
        XCTAssertEqual(ProducerDiagnosticLogLevel.debug.rawValue, 0)
        XCTAssertEqual(ProducerDiagnosticLogLevel.info.rawValue, 1)
        XCTAssertEqual(ProducerDiagnosticLogLevel.warning.rawValue, 2)
        XCTAssertEqual(ProducerDiagnosticLogLevel.error.rawValue, 3)
        XCTAssertEqual(ProducerDiagnosticLogLevel.off.rawValue, 4)
        XCTAssertEqual(ProducerDiagnostic.Kind.unknown.rawValue, -1)
        XCTAssertEqual(ProducerDiagnostic.Kind.openFailed.rawValue, 7)
        XCTAssertEqual(ProducerDiagnostic.Kind.openStarted.rawValue, 8)
        XCTAssertEqual(ProducerDiagnostic.Kind.admissionSummary.rawValue, 9)
        XCTAssertEqual(ProducerDiagnostic.Kind.batchSealed.rawValue, 10)
        XCTAssertEqual(ProducerDiagnostic.Kind.attemptStarted.rawValue, 11)
        XCTAssertEqual(ProducerDiagnostic.Kind.transportFinished.rawValue, 12)
        XCTAssertEqual(ProducerDiagnostic.Kind.transportMetrics.rawValue, 13)
        XCTAssertEqual(ProducerDiagnostic.Kind.lifecycle.rawValue, 14)
        XCTAssertEqual(ProducerDiagnostic.Kind.closeStarted.rawValue, 15)
        XCTAssertEqual(ProducerDiagnostic.Kind.closeFailed.rawValue, 16)
        XCTAssertEqual(ProducerDiagnostic.Kind.diagnosticsDropped.rawValue, 17)
    }

    func testNativeFieldsInitializerCopiesOnlyWhitelistedScalars() {
        let native: NSDictionary = [
            "core_requests_total": NSNumber(value: 4),
            "buffer_used_bytes": NSNumber(value: 128),
            "request_id": "request-1",
            "unknown_object": ["credential": "secret"],
            "add_rejected_by_error": ["buffer_full": NSNumber(value: 2)],
        ]
        let details = ProducerDiagnosticDetails(nativeFields: native)
        XCTAssertEqual(details.coreRequestsTotal, 4)
        XCTAssertEqual(details.bufferUsedBytes, 128)
        XCTAssertEqual(details.requestID, "request-1")
        XCTAssertEqual(details.addRejectedByError?["buffer_full"], 2)
    }

    func testInvalidRequestIDIsNullAndValidRequestIDIsNotTruncated() throws {
        let valid = String(repeating: "R", count: 200)
        var details = ProducerDiagnosticDetails()
        details.requestID = valid
        let validMessage = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(kind: .transportFinished), context: details))
        let validObject = try XCTUnwrap(Self.object(validMessage))
        XCTAssertEqual(validObject["request_id"] as? String, valid)

        details.requestID = "request-id\nwith-secret"
        let invalidMessage = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(kind: .transportFinished), context: details))
        let invalidObject = try XCTUnwrap(Self.object(invalidMessage))
        XCTAssertTrue(invalidObject["request_id"] is NSNull)

        details.requestID = String(repeating: "R", count: 257)
        let overlongMessage = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(kind: .transportFinished), context: details))
        let overlongObject = try XCTUnwrap(Self.object(overlongMessage))
        XCTAssertTrue(overlongObject["request_id"] is NSNull)

        details.requestID = "request/id"
        let punctuationMessage = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(kind: .transportFinished), context: details))
        let punctuationObject = try XCTUnwrap(Self.object(punctuationMessage))
        XCTAssertTrue(punctuationObject["request_id"] is NSNull)
    }

    func testLongOptionalFieldsAreOmittedAsValidJSON() throws {
        var details = ProducerDiagnosticDetails()
        details.producerID = String(repeating: "p", count: 256)
        details.topicID = String(repeating: "t", count: 256)
        details.endpointHost = String(repeating: "e", count: 256)
        details.sdkVersion = String(repeating: "v", count: 128)
        details.attemptID = String(repeating: "a", count: 256)
        details.requestID = String(repeating: "r", count: 512)
        details.producerErrorDomain = String(repeating: "d", count: 256)
        details.producerErrorName = String(repeating: "n", count: 256)
        details.transportKind = String(repeating: "k", count: 256)
        details.transportErrorDomain = String(repeating: "q", count: 256)
        details.underlyingErrorDomain = String(repeating: "u", count: 256)
        details.timeoutSource = String(repeating: "o", count: 256)
        details.cancelSource = String(repeating: "c", count: 256)
        details.appState = String(repeating: "s", count: 256)
        details.networkProtocol = String(repeating: "h", count: 256)
        details.compression = String(repeating: "m", count: 256)
        details.persistenceMode = String(repeating: "w", count: 256)
        details.addRejectedByError = Dictionary(
            uniqueKeysWithValues: (0..<32).map { ("error_\($0)", Int64($0)) })
        let message = try XCTUnwrap(DiagnosticFormatter.format(
            ProducerDiagnostic(kind: .transportMetrics), context: details))
        let data = try XCTUnwrap(message.data(using: .utf8))
        XCTAssertLessThanOrEqual(data.count, DiagnosticFormatter.maxUTF8Bytes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["fields_omitted"] as? Bool, true)
        XCTAssertTrue(json["attempt_id"] is NSNull)
    }

    func testSensitiveValuesNeverAppearInStructuredDetailsOrDescription() throws {
        var details = ProducerDiagnosticDetails()
        details.producerID = "access_key_secret"
        details.endpointHost = "https://user:password@example.com/path?token=secret"
        details.producerErrorName = "untrusted server response"
        details.underlyingErrorDomain = "NSError userInfo secret"
        details.errorCode = "authorization=Bearer-secret"
        let value = ProducerDiagnostic(kind: .openFailed, context: details)
        let sanitized = DiagnosticFormatter.sanitizeContext(value.context ?? ProducerDiagnosticDetails())
        let dto = TLSProducerDiagnostic(value)
        let description = String(describing: dto)
        XCTAssertNil(sanitized.producerID)
        XCTAssertEqual(sanitized.endpointHost, "example.com")
        XCTAssertNil(sanitized.producerErrorName)
        XCTAssertNil(sanitized.underlyingErrorDomain)
        XCTAssertNil(sanitized.errorCode)
        XCTAssertFalse(description.contains("secret"))
        let message = try XCTUnwrap(DiagnosticFormatter.format(value, context: sanitized))
        XCTAssertFalse(message.contains("secret"))
        XCTAssertFalse(message.contains("password"))
    }

    private static func object(_ message: String) -> [String: Any]? {
        guard let data = message.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
