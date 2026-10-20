import Foundation

/// Retry limits for one delivery cycle. Attempts include the first request.
public struct RetryConfiguration: Equatable, Sendable {
    /// Zero removes the attempt-count limit; `totalTimeout` still applies.
    public var maxAttempts: Int
    public var totalTimeout: TimeInterval
    public var initialInterval: TimeInterval
    /// Nominal backoff ceiling before the Core's 20% jitter is applied.
    public var maxInterval: TimeInterval
    /// Retry received 408/499 and structured transient upload errors in 400
    /// responses. Parameter errors and unknown 400 responses stay terminal.
    public var retryTransientHTTPResponses: Bool

    public init(maxAttempts: Int = 0, totalTimeout: TimeInterval = 90,
                initialInterval: TimeInterval = 0.5, maxInterval: TimeInterval = 10,
                retryTransientHTTPResponses: Bool = true) {
        self.maxAttempts = maxAttempts
        self.totalTimeout = totalTimeout
        self.initialInterval = initialInterval
        self.maxInterval = maxInterval
        self.retryTransientHTTPResponses = retryTransientHTTPResponses
    }

    internal func validate() throws {
        guard (0...50).contains(maxAttempts) else {
            throw ProducerError.configuration("retry.maxAttempts must be between 0 and 50")
        }
        try ProducerConfiguration.validateMilliseconds(totalTimeout, name: "retry.totalTimeout", allowZero: false)
        try ProducerConfiguration.validateMilliseconds(initialInterval, name: "retry.initialInterval", allowZero: false)
        try ProducerConfiguration.validateMilliseconds(maxInterval, name: "retry.maxInterval", allowZero: false)
        guard (0.1...30).contains(initialInterval) else {
            throw ProducerError.configuration("retry.initialInterval must be between 0.1 and 30 seconds")
        }
        guard (1...60).contains(maxInterval), maxInterval >= initialInterval else {
            throw ProducerError.configuration("retry.maxInterval must be between 1 and 60 seconds and at least initialInterval")
        }
    }
}
