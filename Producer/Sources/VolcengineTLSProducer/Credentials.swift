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

    // MARK: - Redaction

    /// Always redacted. Never reveals AK/SK/token.
    public var description: String { "Credentials(<redacted>)" }

    /// Always redacted. Never reveals AK/SK/token.
    public var debugDescription: String { "Credentials(<redacted>)" }
}

extension Credentials: CustomStringConvertible, CustomDebugStringConvertible {}
