import Foundation
import XCTest
@testable import VolcengineTLSProducer

final class RetryConfigurationTests: XCTestCase {
    func testAndroidAlignedDefaultsAndSeparateTimeouts() throws {
        let config = try ProducerConfiguration()
        XCTAssertEqual(config.retry.maxAttempts, 0)
        XCTAssertEqual(config.retry.totalTimeout, 90)
        XCTAssertEqual(config.retry.initialInterval, 0.5)
        XCTAssertEqual(config.retry.maxInterval, 10)
        XCTAssertEqual(config.requestIdleTimeout, 50)
        XCTAssertEqual(config.requestTimeout, 90)
        XCTAssertEqual(config.memoryRetryRetention, 0)
        XCTAssertTrue(config.retry.retryTransientHTTPResponses)
    }

    func testRetryValidationAndOpenRevalidation() throws {
        for retry in [RetryConfiguration(maxAttempts: -1),
                      RetryConfiguration(maxAttempts: 51),
                      RetryConfiguration(totalTimeout: 0),
                      RetryConfiguration(initialInterval: 0.099),
                      RetryConfiguration(initialInterval: 31),
                      RetryConfiguration(maxInterval: 0.999),
                      RetryConfiguration(maxInterval: 61),
                      RetryConfiguration(initialInterval: 2, maxInterval: 1)] {
            XCTAssertThrowsError(try ProducerConfiguration(retry: retry))
        }
        var config = try ProducerConfiguration()
        config.retry.totalTimeout = .nan
        XCTAssertThrowsError(try config.validatedForOpen(requireDestination: false))
        config = try ProducerConfiguration()
        config.requestIdleTimeout = 0
        XCTAssertThrowsError(try config.validatedForOpen(requireDestination: false))
        config = try ProducerConfiguration()
        config.memoryRetryRetention = -1
        XCTAssertThrowsError(try config.validatedForOpen(requireDestination: false))
    }

    func testRetentionIsIndependentFromAttemptBudgetAndSnapshots() throws {
        var config = try ProducerConfiguration(
            retry: RetryConfiguration(maxAttempts: 3, totalTimeout: 30),
            memoryRetryRetention: 24 * 60 * 60)
        let frozen = ConfigurationSnapshot(config)
        config.retry.maxAttempts = 1
        config.memoryRetryRetention = 0
        XCTAssertEqual(frozen.retry.maxAttempts, 3)
        XCTAssertEqual(frozen.retry.totalTimeout, 30)
        XCTAssertEqual(frozen.memoryRetryRetention, 86_400)
    }

    func testObjectiveCConfigurationRoundTripsNewFields() throws {
        let config = TLSProducerConfiguration()
        XCTAssertEqual(config.retryMaxAttempts, 0)
        XCTAssertEqual(config.requestIdleTimeout, 50)
        config.retryTransientHTTPResponses = false
        config.retryMaxAttempts = 7
        config.retryTotalTimeout = 20
        config.retryInitialInterval = 0.2
        config.retryMaxInterval = 2
        config.memoryRetryRetention = 86_400
        config.requestIdleTimeout = 40
        let swift = try config.swiftValue()
        XCTAssertEqual(swift.retry, RetryConfiguration(
            maxAttempts: 7, totalTimeout: 20, initialInterval: 0.2, maxInterval: 2,
            retryTransientHTTPResponses: false))
        XCTAssertEqual(swift.requestIdleTimeout, 40)
        XCTAssertEqual(swift.memoryRetryRetention, 86_400)
    }
}
