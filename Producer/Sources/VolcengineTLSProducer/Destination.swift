//
//  Destination.swift
//  VolcengineTLSProducer
//
//  Worker A — Swift public value model.
//

import Foundation

/// The destination identity for a producer: endpoint, region, project and
/// topic.
///
/// A destination is always replaced as a whole via
/// `Producer.updateDestination(_:)`; there are no per-field setters.
/// With the bundled C Core v0.3.1, wire routing is determined by endpoint,
/// region and topic. `projectID` is retained for future project-domain
/// routing and receives only minimum transport-safe validation in this
/// release. Changing it alone does not retarget requests because the bundled
/// Core ABI has no project update parameter.
/// Construction does not throw, so a destination can be built declaratively;
/// validation runs at `Producer.open` / `updateDestination` time via
/// `validate()`.
public struct Destination: Equatable, Sendable {

    /// Service endpoint URL, e.g. `https://tls-cn-beijing.volces.com`.
    /// Must be an HTTPS origin with a host (an explicit port is allowed), and
    /// carry no path, query, userinfo, or fragment.
    public var endpoint: String

    /// Region ID, e.g. `cn-beijing`. Non-empty.
    public var region: String

    /// TLS Project ID. Reserved for future project-domain routing. This
    /// release requires a non-empty value without NUL or line breaks, but
    /// intentionally does not guess a service length or character set.
    /// It is not part of request routing in bundled C Core v0.3.1.
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
              scheme == "https",
              components.url != nil else {
            throw ProducerError.configuration("endpoint must be an https URL: \(Self.redactedEndpoint(endpoint))")
        }
        guard let host = components.host, !host.isEmpty else {
            throw ProducerError.configuration("endpoint must have a host")
        }
        // No userinfo (user/password) and no fragment.
        if components.user != nil || components.password != nil {
            throw ProducerError.configuration("endpoint must not contain userinfo")
        }
        if !components.path.isEmpty {
            throw ProducerError.configuration("endpoint must not contain a path")
        }
        if components.query != nil {
            throw ProducerError.configuration("endpoint must not contain a query")
        }
        if components.fragment != nil {
            throw ProducerError.configuration("endpoint must not contain a fragment")
        }
        if endpoint.hasSuffix(":") {
            throw ProducerError.configuration("endpoint port must not be empty")
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw ProducerError.configuration("endpoint port must be between 1 and 65535")
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
        guard !region.contains("\0"),
              !projectID.contains("\0"),
              !topicID.contains("\0") else {
            throw ProducerError.configuration(
                "destination fields must not contain embedded NUL characters")
        }
        guard endpoint.rangeOfCharacter(from: .newlines) == nil,
              region.rangeOfCharacter(from: .newlines) == nil,
              projectID.rangeOfCharacter(from: .newlines) == nil,
              topicID.rangeOfCharacter(from: .newlines) == nil else {
            throw ProducerError.configuration(
                "destination fields must not contain line break characters")
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
