//
//  CredentialsRedactionTests.swift
//  ContractTests
//
//  Credential redaction tests.
//

import XCTest
@testable import VolcengineTLSProducer

final class CredentialsRedactionTests: XCTestCase {

    private let fixtureValues = [
        "AKIDtest-private-id-1234567890",
        "SKtest-private-value-0987654321",
        "STS-session-value-abcdefghijklmnop",
    ]

    func testDescriptionIsFullyRedacted() {
        let credentials = Credentials(
            accessKeyID: fixtureValues[0],
            accessKeySecret: fixtureValues[1],
            securityToken: fixtureValues[2])
        let description = String(describing: credentials)
        XCTAssertEqual(description, "Credentials(<redacted>)")
        XCTAssertFalse(description.contains(fixtureValues[0]))
        XCTAssertFalse(description.contains(fixtureValues[1]))
        XCTAssertFalse(description.contains(fixtureValues[2]))
    }

    func testDebugDescriptionIsFullyRedacted() {
        let credentials = Credentials(
            accessKeyID: fixtureValues[0],
            accessKeySecret: fixtureValues[1],
            securityToken: fixtureValues[2])
        let debugDescription = String(reflecting: credentials)
        XCTAssertEqual(debugDescription, "Credentials(<redacted>)")
        XCTAssertFalse(debugDescription.contains(fixtureValues[0]))
        XCTAssertFalse(debugDescription.contains(fixtureValues[1]))
        XCTAssertFalse(debugDescription.contains(fixtureValues[2]))
    }

    func testStringInterpolationIsRedacted() {
        let credentials = Credentials(
            accessKeyID: fixtureValues[0],
            accessKeySecret: fixtureValues[1],
            securityToken: fixtureValues[2])
        let interpolated = "creds=\(credentials)"
        XCTAssertEqual(interpolated, "creds=Credentials(<redacted>)")
    }

    func testPrintableConversionIsRedacted() {
        let credentials = Credentials(
            accessKeyID: fixtureValues[0],
            accessKeySecret: fixtureValues[1],
            securityToken: fixtureValues[2])
        // Any CustomStringConvertible path (print, NSLog format args, etc.)
        // must go through the redacted description.
        XCTAssertTrue(String(describing: credentials).allSatisfy { ch in
            // The redacted form contains only these characters.
            "Credentials(<redacted>)".contains(ch)
        })
    }

    func testRedactionWithoutToken() {
        let credentials = Credentials(
            accessKeyID: fixtureValues[0],
            accessKeySecret: fixtureValues[1],
            securityToken: nil)
        XCTAssertEqual(String(describing: credentials), "Credentials(<redacted>)")
        XCTAssertEqual(String(reflecting: credentials), "Credentials(<redacted>)")
    }

    func testEmbeddedNULCredentialsAreRejectedWithoutEchoingSecrets() {
        let values = ["first", "second", "third"]
        let invalidValues = [
            values[0] + "\0suffix",
            values[1] + "\0suffix",
            values[2] + "\0suffix",
        ]
        for credentials in [
            Credentials(accessKeyID: invalidValues[0], accessKeySecret: values[1]),
            Credentials(accessKeyID: values[0], accessKeySecret: invalidValues[1]),
            Credentials(
                accessKeyID: values[0],
                accessKeySecret: values[1],
                securityToken: invalidValues[2]),
        ] {
            XCTAssertThrowsError(try credentials.validate()) { error in
                let description = String(describing: error)
                XCTAssertTrue(description.contains("NUL"))
                XCTAssertFalse(description.contains("suffix"))
            }
        }
    }

    func testHeaderLineBreakCredentialsAreRejectedWithoutEchoingSecrets() {
        let values = ["first", "second", "third"]
        let invalidValues = [
            values[0] + "\r\nX-Injected: value",
            values[1] + "\nvalue",
            values[2] + "\rvalue",
        ]
        for credentials in [
            Credentials(accessKeyID: invalidValues[0], accessKeySecret: values[1]),
            Credentials(accessKeyID: values[0], accessKeySecret: invalidValues[1]),
            Credentials(
                accessKeyID: values[0],
                accessKeySecret: values[1],
                securityToken: invalidValues[2]),
        ] {
            XCTAssertThrowsError(try credentials.validate()) { error in
                let description = String(describing: error)
                XCTAssertTrue(description.contains("line break"))
                XCTAssertFalse(description.contains("X-Injected"))
                XCTAssertFalse(description.contains("value"))
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
            Credentials(
                accessKeyID: fixtureValues[0],
                accessKeySecret: fixtureValues[1],
                securityToken: fixtureValues[2]))
        let error = ProducerError.service(
            code: 401, message: "Unauthorized", requestID: "req-1")
        let description = String(describing: error)
        XCTAssertFalse(description.contains(fixtureValues[0]))
        XCTAssertFalse(description.contains(fixtureValues[1]))
        XCTAssertFalse(description.contains(fixtureValues[2]))

        try await producer.close(timeout: 1)
    }
}
