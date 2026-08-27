//
//  DestinationValidationTests.swift
//  ContractTests
//
//  Worker A — endpoint/region/project/topic validation.
//

import XCTest
@testable import VolcengineTLSProducer

final class DestinationValidationTests: XCTestCase {

    // MARK: - Valid

    func testValidDestinations() throws {
        XCTAssertNoThrow(
            try Destination(
                endpoint: "https://tls-cn-beijing.volces.com",
                region: "cn-beijing",
                projectID: "project",
                topicID: "topic"
            ).validate())

        XCTAssertNoThrow(
            try Destination(
                endpoint: "https://tls-cn-beijing.volces.com:8443/path",
                region: "cn-beijing",
                projectID: "project",
                topicID: "topic"
            ).validate())

        // Query is allowed (only userinfo/fragment are forbidden).
        XCTAssertNoThrow(
            try Destination(
                endpoint: "https://host.example.com?query=1",
                region: "r",
                projectID: "p",
                topicID: "t"
            ).validate())

        // Scheme is case-insensitive.
        XCTAssertNoThrow(
            try Destination(
                endpoint: "HTTPS://host.example.com",
                region: "r",
                projectID: "p",
                topicID: "t"
            ).validate())
    }

    // MARK: - Endpoint scheme

    func testHTTPSEndpointRequired() {
        XCTAssertThrowsError(
            try Destination(
                endpoint: "http://host.example.com",
                region: "r", projectID: "p", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "https")
        }
    }

    func testEndpointWithoutSchemeRejected() {
        XCTAssertThrowsError(
            try Destination(
                endpoint: "host.example.com",
                region: "r", projectID: "p", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "https")
        }
    }

    // MARK: - Host

    func testEndpointWithoutHostRejected() {
        XCTAssertThrowsError(
            try Destination(
                endpoint: "https://",
                region: "r", projectID: "p", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "host")
        }
    }

    // MARK: - Userinfo / fragment

    func testEndpointWithUserinfoRejected() {
        XCTAssertThrowsError(
            try Destination(
                endpoint: "https://user@host.example.com",
                region: "r", projectID: "p", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "userinfo")
        }
        XCTAssertThrowsError(
            try Destination(
                endpoint: "https://user:pass@host.example.com",
                region: "r", projectID: "p", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "userinfo")
        }
    }

    func testEndpointWithFragmentRejected() {
        XCTAssertThrowsError(
            try Destination(
                endpoint: "https://host.example.com#fragment",
                region: "r", projectID: "p", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "fragment")
        }
    }

    // MARK: - Non-empty fields

    func testEmptyRegionRejected() {
        XCTAssertThrowsError(
            try Destination(
                endpoint: "https://host.example.com",
                region: "", projectID: "p", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "region")
        }
    }

    func testEmptyProjectIDRejected() {
        XCTAssertThrowsError(
            try Destination(
                endpoint: "https://host.example.com",
                region: "r", projectID: "", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "projectID")
        }
    }

    func testEmptyTopicIDRejected() {
        XCTAssertThrowsError(
            try Destination(
                endpoint: "https://host.example.com",
                region: "r", projectID: "p", topicID: ""
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "topicID")
        }
    }

    // MARK: - updateDestination integration

    func testUpdateDestinationValidates() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        XCTAssertNoThrow(try producer.updateDestination(.testing))
        XCTAssertEqual(recording.updateDestinationCalls.count, 1)
        XCTAssertEqual(recording.updateDestinationCalls.first, .testing)

        XCTAssertThrowsError(
            try producer.updateDestination(
                Destination(endpoint: "http://host", region: "r", projectID: "p", topicID: "t"))
        ) { error in
            assertConfigurationError(error, containing: "https")
        }
        // The adapter must not have seen the invalid destination.
        XCTAssertEqual(recording.updateDestinationCalls.count, 1)

        try await producer.close(timeout: 1)
    }

    // MARK: - Helpers

    private func assertConfigurationError(
        _ error: Error,
        containing fragment: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard case ProducerError.configuration(let reason) = error else {
            XCTFail("expected .configuration, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            reason.contains(fragment),
            "reason '\(reason)' should contain '\(fragment)'",
            file: file,
            line: line)
    }
}
