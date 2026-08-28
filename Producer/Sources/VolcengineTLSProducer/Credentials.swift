//
//  Credentials.swift
//  VolcengineTLSProducer
//
//  Worker A — Swift public value model.
//

import Foundation

/// Volcengine access credentials: access key ID, secret, and optional STS
/// security token.
///
/// Credentials are always replaced as a whole group via
/// `Producer.updateCredentials(_:)` (atomic semantics). The SDK never writes
/// credentials to `UserDefaults`, files, logs, metrics, or error
/// descriptions.
public struct Credentials: Equatable, Sendable {

    public var accessKeyID: String
    public var accessKeySecret: String
    public var securityToken: String?

    public init(accessKeyID: String,
                accessKeySecret: String,
                securityToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.accessKeySecret = accessKeySecret
        self.securityToken = securityToken
    }

    /// Validates the credential group at each open/update boundary. The
    /// initializer remains non-throwing for source compatibility; callers
    /// must not pass an empty access key or secret to the Core.
    internal func validate() throws {
        guard !accessKeyID.isEmpty else {
            throw ProducerError.configuration("credentials.accessKeyID must not be empty")
        }
        guard !accessKeySecret.isEmpty else {
            throw ProducerError.configuration("credentials.accessKeySecret must not be empty")
        }
        guard !accessKeyID.contains("\0"),
              !accessKeySecret.contains("\0"),
              securityToken?.contains("\0") != true else {
            throw ProducerError.configuration(
                "credentials must not contain embedded NUL characters")
        }
        guard accessKeyID.rangeOfCharacter(from: .newlines) == nil,
              accessKeySecret.rangeOfCharacter(from: .newlines) == nil,
              securityToken?.rangeOfCharacter(from: .newlines) == nil else {
            throw ProducerError.configuration(
                "credentials must not contain line break characters")
        }
    }

    // MARK: - Redaction

    /// Always redacted. Never reveals AK/SK/token.
    public var description: String { "Credentials(<redacted>)" }

    /// Always redacted. Never reveals AK/SK/token.
    public var debugDescription: String { "Credentials(<redacted>)" }
}

extension Credentials: CustomStringConvertible, CustomDebugStringConvertible {}
