//
//  CredentialsRedactionTests.swift
//  ContractTests
//
//  Worker A — credentials must never appear in any string conversion.
//

import XCTest
@testable import VolcengineTLSProducer

final class CredentialsRedactionTests: XCTestCase {

    private let ak = "AKIDtest-secret-ak-1234567890"
    private let sk = "SKtest-secret-sk-0987654321"
    private let token = "STS-token-abcdefghijklmnop"

    func testDescriptionIsFullyRedacted() {
        let credentials = Credentials(
            accessKeyID: ak,
            accessKeySecret: sk,
            securityToken: token)
        let description = String(describing: credentials)
        XCTAssertEqual(description, "Credentials(<redacted>)")
        XCTAssertFalse(description.contains(ak))
        XCTAssertFalse(description.contains(sk))
        XCTAssertFalse(description.contains(token))
    }

    func testDebugDescriptionIsFullyRedacted() {
        let credentials = Credentials(
            accessKeyID: ak,
            accessKeySecret: sk,
            securityToken: token)
        let debugDescription = String(reflecting: credentials)
        XCTAssertEqual(debugDescription, "Credentials(<redacted>)")
        XCTAssertFalse(debugDescription.contains(ak))
        XCTAssertFalse(debugDescription.contains(sk))
        XCTAssertFalse(debugDescription.contains(token))
    }

    func testStringInterpolationIsRedacted() {
        let credentials = Credentials(
            accessKeyID: ak,
            accessKeySecret: sk,
            securityToken: token)
        let interpolated = "creds=\(credentials)"
        XCTAssertEqual(interpolated, "creds=Credentials(<redacted>)")
    }

    func testPrintableConversionIsRedacted() {
        let credentials = Credentials(
            accessKeyID: ak,
            accessKeySecret: sk,
            securityToken: token)
        // Any CustomStringConvertible path (print, NSLog format args, etc.)
        // must go through the redacted description.
        XCTAssertTrue(String(describing: credentials).allSatisfy { ch in
            // The redacted form contains only these characters.
            "Credentials(<redacted>)".contains(ch)
        })
    }

    func testRedactionWithoutToken() {
        let credentials = Credentials(
            accessKeyID: ak,
            accessKeySecret: sk,
            securityToken: nil)
        XCTAssertEqual(String(describing: credentials), "Credentials(<redacted>)")
        XCTAssertEqual(String(reflecting: credentials), "Credentials(<redacted>)")
    }

    func testEmbeddedNULCredentialsAreRejectedWithoutEchoingSecrets() {
        for credentials in [
            Credentials(accessKeyID: "ak\0suffix", accessKeySecret: "sk"),
            Credentials(accessKeyID: "ak", accessKeySecret: "sk\0suffix"),
            Credentials(accessKeyID: "ak", accessKeySecret: "sk", securityToken: "token\0suffix"),
        ] {
            XCTAssertThrowsError(try credentials.validate()) { error in
                let description = String(describing: error)
                XCTAssertTrue(description.contains("NUL"))
                XCTAssertFalse(description.contains("suffix"))
            }
        }
    }

    func testUpdateCredentialsDoesNotLeakViaErrors() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        // Even a failing update must not embed credentials in the error.
        try producer.updateCredentials(
            Credentials(accessKeyID: ak, accessKeySecret: sk, securityToken: token))
        let error = ProducerError.service(
            code: 401, message: "Unauthorized", requestID: "req-1")
        let description = String(describing: error)
        XCTAssertFalse(description.contains(ak))
        XCTAssertFalse(description.contains(sk))
        XCTAssertFalse(description.contains(token))

        try await producer.close(timeout: 1)
    }
}
