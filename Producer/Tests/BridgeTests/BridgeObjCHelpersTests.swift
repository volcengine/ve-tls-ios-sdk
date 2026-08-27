// BridgeObjCHelpersTests.swift
// BridgeTests
//
// Activates the ObjC Bridge helpers' built-in self-checks now that the
// umbrella header exports them (import TLSProducerBridge).
//

import XCTest
import TLSProducerBridge
import CTLSProducerCore

final class BridgeObjCHelpersTests: XCTestCase {

    func testRedactingLoggerSelfCheckPasses() {
        // Exercises URL query/fragment stripping, authorization/x-tls-*
        // masking, and the clean-input detector.
        XCTAssertTrue(TLSRedactingLogger.runBuiltInSelfCheck())
    }

    func testMalformedURLFallbackRedaction() {
        // Malformed URL: fallback cuts at the first '?' or '#'.
        XCTAssertEqual(
            TLSRedactingLogger.redactedURLString("not-a-url?authorization=abc#frag"),
            "not-a-url")
        XCTAssertEqual(
            TLSRedactingLogger.redactedURLString("garbage#fragment"),
            "garbage")
    }

    func testValidURLStripsQueryFragmentAndUserinfo() {
        // Query and fragment stripped.
        XCTAssertEqual(
            TLSRedactingLogger.redactedURLString(
                "https://tls-cn-beijing.volces.com/PutLogs?x-tls-token=secret#frag"),
            "https://tls-cn-beijing.volces.com/PutLogs")
        // L1: userinfo stripped.
        XCTAssertEqual(
            TLSRedactingLogger.redactedURLString("https://user:pass@host.example/path"),
            "https://host.example/path")
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
        // The C Core is now integrated (v0.3.1); verify the version probe
        // returns a non-empty string.
        let version = String(cString: ve_tls_iosp_core_version())
        XCTAssertFalse(version.isEmpty, "C Core version must be non-empty")
    }
}
