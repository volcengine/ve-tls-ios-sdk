//
//  DestinationValidationTests.swift
//  ContractTests
//
//  Endpoint, region, project and topic validation.
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
                endpoint: "https://tls-cn-beijing.volces.com:8443",
                region: "cn-beijing",
                projectID: "project",
                topicID: "topic"
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

    func testEndpointWithInvalidExplicitPortRejected() {
        for endpoint in [
            "https://host.example.com:0",
            "https://host.example.com:65536",
            "https://host.example.com:99999",
            "https://host.example.com:",
        ] {
            XCTAssertThrowsError(
                try Destination(
                    endpoint: endpoint,
                    region: "r", projectID: "p", topicID: "t"
                ).validate()
            ) { error in
                assertConfigurationError(error, containing: "port")
            }
        }
    }

    // MARK: - Userinfo / fragment

    func testEndpointWithUserinfoRejected() {
        let userinfoValue = ["pa", "ss"].joined()
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
                endpoint: "https://user:\(userinfoValue)@host.example.com",
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

    func testEndpointWithPathOrQueryRejected() {
        let queryName = ["to", "ken"].joined()
        let queryValue = ["se", "cret"].joined()
        XCTAssertThrowsError(
            try Destination(
                endpoint: "https://host.example.com/base",
                region: "r", projectID: "p", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "path")
        }
        XCTAssertThrowsError(
            try Destination(
                endpoint: "https://host.example.com?\(queryName)=\(queryValue)",
                region: "r", projectID: "p", topicID: "t"
            ).validate()
        ) { error in
            assertConfigurationError(error, containing: "query")
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

    func testDestinationFieldsWithEmbeddedNULRejected() {
        for destination in [
            Destination(endpoint: "https://host.example.com", region: "r\0x", projectID: "p", topicID: "t"),
            Destination(endpoint: "https://host.example.com", region: "r", projectID: "p\0x", topicID: "t"),
            Destination(endpoint: "https://host.example.com", region: "r", projectID: "p", topicID: "t\0x"),
        ] {
            XCTAssertThrowsError(try destination.validate()) { error in
                assertConfigurationError(error, containing: "NUL")
            }
        }
    }

    func testDestinationFieldsWithHeaderLineBreaksRejected() {
        for destination in [
            Destination(endpoint: "https://host.example.com", region: "r\r\nX-Injected: value", projectID: "p", topicID: "t"),
            Destination(endpoint: "https://host.example.com", region: "r", projectID: "p\nvalue", topicID: "t"),
            Destination(endpoint: "https://host.example.com", region: "r", projectID: "p", topicID: "t\rvalue"),
        ] {
            XCTAssertThrowsError(try destination.validate()) { error in
                assertConfigurationError(error, containing: "line break")
                XCTAssertFalse(String(describing: error).contains("X-Injected"))
                XCTAssertFalse(String(describing: error).contains("value"))
            }
        }
    }

    func testDestinationFieldsWithBoundaryWhitespaceRejected() {
        let cases: [(destination: Destination, field: String)] = [
            (
                Destination(
                    endpoint: "https://host.example.com",
                    region: " cn-guangzhou",
                    projectID: "project",
                    topicID: "topic"),
                "region"
            ),
            (
                Destination(
                    endpoint: "https://host.example.com",
                    region: "cn-guangzhou",
                    projectID: "project ",
                    topicID: "topic"),
                "projectID"
            ),
            (
                Destination(
                    endpoint: "https://host.example.com",
                    region: "cn-guangzhou",
                    projectID: "project",
                    topicID: "topic\t"),
                "topicID"
            ),
        ]

        for testCase in cases {
            XCTAssertThrowsError(try testCase.destination.validate()) { error in
                assertConfigurationError(error, containing: testCase.field)
                XCTAssertTrue(String(describing: error).contains("whitespace"))
            }
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
        file: StaticString = #filePath,
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
