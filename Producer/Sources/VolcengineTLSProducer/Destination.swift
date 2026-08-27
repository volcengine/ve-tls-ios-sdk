//
//  Destination.swift
//  VolcengineTLSProducer
//
//  Worker A — Swift public value model.
//

import Foundation

/// The atomic set of routing fields for a producer: endpoint, region,
/// project and topic.
///
/// A destination is always replaced as a whole via
/// `Producer.updateDestination(_:)`; there are no per-field setters.
/// Construction does not throw, so a destination can be built declaratively;
/// validation runs at `Producer.open` / `updateDestination` time via
/// `validate()`.
public struct Destination: Equatable, Sendable {

    /// Service endpoint URL, e.g. `https://tls-cn-beijing.volces.com`.
    /// Must be HTTPS, have a host, and carry no userinfo or fragment.
    public var endpoint: String

    /// Region ID, e.g. `cn-beijing`. Non-empty.
    public var region: String

    /// TLS Project ID. Non-empty.
    public var projectID: String

    /// TLS Topic ID. Non-empty.
    public var topicID: String

    public init(endpoint: String,
                region: String,
                projectID: String,
                topicID: String) {
        self.endpoint = endpoint
        self.region = region
        self.projectID = projectID
        self.topicID = topicID
    }

    /// Validates all fields. Throws `ProducerError.configuration` on the first
    /// violated rule.
    public func validate() throws {
        guard let components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" else {
            throw ProducerError.configuration("endpoint must be an https URL: \(Self.redactedEndpoint(endpoint))")
        }
        guard let host = components.host, !host.isEmpty else {
            throw ProducerError.configuration("endpoint must have a host")
        }
        // No userinfo (user/password) and no fragment.
        if components.user != nil || components.password != nil {
            throw ProducerError.configuration("endpoint must not contain userinfo")
        }
        if components.fragment != nil {
            throw ProducerError.configuration("endpoint must not contain a fragment")
        }
        guard !region.isEmpty else {
            throw ProducerError.configuration("region must not be empty")
        }
        guard !projectID.isEmpty else {
            throw ProducerError.configuration("projectID must not be empty")
        }
        guard !topicID.isEmpty else {
            throw ProducerError.configuration("topicID must not be empty")
        }
    }

    /// Endpoint text is not secret, but error descriptions must stay free of
    /// user-supplied URL components that could embed credentials; keep the
    /// host only.
    private static func redactedEndpoint(_ endpoint: String) -> String {
        if let components = URLComponents(string: endpoint),
           let host = components.host, !host.isEmpty {
            return "https://\(host)"
        }
        return "<invalid>"
    }
}
