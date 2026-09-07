// BridgeObjCHelpersTests.swift
// BridgeTests
//
// Activates the ObjC Bridge helpers' built-in self-checks now that the
// umbrella header exports them (import TLSProducerBridge).
//

import XCTest
import TLSProducerBridge

final class BridgeObjCHelpersTests: XCTestCase {

    func testRedactingLoggerSelfCheckPasses() {
        // Exercises URL query/fragment stripping, authorization/x-tls-*
        // masking, and the clean-input detector.
        XCTAssertTrue(TLSRedactingLogger.runBuiltInSelfCheck())
    }

    func testTransportLoggingIsDisabledByDefaultAndRequiresExplicitOptIn() {
        XCTAssertFalse(TLSRedactingLogger.isLoggingEnabled)
        defer { TLSRedactingLogger.isLoggingEnabled = false }

        TLSRedactingLogger.isLoggingEnabled = true
        XCTAssertTrue(TLSRedactingLogger.isLoggingEnabled)

        TLSRedactingLogger.isLoggingEnabled = false
        XCTAssertFalse(TLSRedactingLogger.isLoggingEnabled)
    }

    func testRelativeURLRedaction() {
        // These are parseable relative URLs, not parser failures.
        XCTAssertEqual(
            TLSRedactingLogger.redactedURLString("not-a-url?authorization=abc#frag"),
            "not-a-url")
        XCTAssertEqual(
            TLSRedactingLogger.redactedURLString("garbage#fragment"),
            "garbage")
    }

    func testUnparseableURLNeverReturnsUserinfo() {
        let userinfo = "sample:synthetic-password"
        let malformed = [
            "https://\(userinfo)@[invalid/path?query=value#fragment",
            "https://\(userinfo)@host.example:invalid/path?query=value#fragment",
            "https://\(userinfo)@extra@[invalid/path",
        ]
        for input in malformed {
            XCTAssertNil(URLComponents(string: input), "fixture must exercise the fallback")
            let result = TLSRedactingLogger.redactedURLString(input)
            XCTAssertEqual(result, TLSRedactedMarker)
            XCTAssertFalse(result.contains(userinfo))
            XCTAssertFalse(result.contains("query=value"))
        }
        XCTAssertEqual(TLSRedactingLogger.redactedURLString(""), "")
    }

    func testValidURLStripsQueryFragmentAndUserinfo() {
        let queryName = ["to", "ken"].joined()
        let queryValue = ["se", "cret"].joined()
        let userinfoValue = ["pa", "ss"].joined()
        // Query and fragment stripped.
        XCTAssertEqual(
            TLSRedactingLogger.redactedURLString(
                "https://tls-cn-beijing.volces.com/PutLogs?x-tls-\(queryName)=\(queryValue)#frag"),
            "https://tls-cn-beijing.volces.com/PutLogs")
        // L1: userinfo stripped.
        XCTAssertEqual(
            TLSRedactingLogger.redactedURLString("https://user:\(userinfoValue)@host.example/path"),
            "https://host.example/path")
    }

    func testRequestIDNormalizationAndFingerprintNeverEchoRawServerText() {
        let serverControlled = "rid/with spaces/" + String(repeating: "A", count: 300)
        let normalized = TLSRedactingLogger.normalizedRequestID(serverControlled)
        XCTAssertEqual(normalized?.count, 256)
        XCTAssertTrue(normalized?.hasPrefix("rid_with_spaces_") == true)
        XCTAssertFalse(normalized?.contains("/") == true)
        XCTAssertFalse(normalized?.contains(" ") == true)

        let fingerprint = TLSRedactingLogger.requestIDFingerprintForLogging(serverControlled)
        XCTAssertTrue(fingerprint.hasPrefix("fnv1a64-"))
        XCTAssertFalse(fingerprint.contains(serverControlled))
        XCTAssertEqual(
            fingerprint,
            TLSRedactingLogger.requestIDFingerprintForLogging(serverControlled))
        XCTAssertNotEqual(
            fingerprint,
            TLSRedactingLogger.requestIDFingerprintForLogging("different-request-id"))
    }

    func testSerialQueueFactoryLabelAndQoS() {
        let queue = TLSSerialQueueFactory.serialQueue(withSuffix: "test")
        XCTAssertEqual(
            queue.label,
            "com.volcengine.tls.producer.test")
        XCTAssertEqual(queue.qos, .utility)
    }

    func testThreadAssertionsDoNotCrashOnCorrectUsage() {
        // Positive usage only: the negative cases trap in debug builds and
        // must not be exercised by XCTest.
        let queue = TLSSerialQueueFactory.serialQueue(withSuffix: "assert")
        let done = expectation(description: "assertions ran on the right queue")
        queue.async {
            TLSAssertNotMainThread()
            TLSAssertIsOnQueue(queue)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testRealCoreAdapterVersion() {
        // Keep the hidden C ABI behind the package-internal ObjC bridge.
        let version = TLSRealCoreAdapter.coreVersion
        XCTAssertFalse(version.isEmpty, "C Core version must be non-empty")
    }
}
