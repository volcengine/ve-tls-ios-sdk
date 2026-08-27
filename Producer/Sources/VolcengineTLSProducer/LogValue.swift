//
//  LogValue.swift
//  VolcengineTLSProducer
//
//  Worker A — Swift public value model.
//

import Foundation

/// Typed value of a single log content field.
///
/// `LogValue` is a value type. Collections (`array`/`dictionary`) are value types
/// too, so cycles are impossible by construction; nesting depth is still bounded
/// (see `LogValue.maxNestingDepth`).
public enum LogValue: Equatable, Sendable {
    case string(String)
    case signedInt(Int64)
    case unsignedInt(UInt64)
    case double(Double)
    case bool(Bool)
    case null
    case array([LogValue])
    case dictionary([String: LogValue])
    /// Raw bytes written as UTF-8 text. Never Base64-encoded implicitly; callers
    /// that need Base64 must encode themselves before wrapping.
    case utf8Data(Data)

    /// Maximum allowed container nesting depth. Deeper values are rejected.
    internal static let maxNestingDepth = 32
}

/// Encoding error raised while turning a `LogValue` into its on-the-wire string.
internal enum LogValueEncodingError: Error, Equatable, CustomStringConvertible {
    case nonFiniteDouble
    case invalidUTF8Data
    case nestingDepthExceeded

    var description: String {
        switch self {
        case .nonFiniteDouble:
            return "double must be finite (NaN/Infinity are not allowed)"
        case .invalidUTF8Data:
            return "utf8Data is not valid UTF-8"
        case .nestingDepthExceeded:
            return "nesting depth exceeds \(LogValue.maxNestingDepth)"
        }
    }
}

extension LogValue {

    /// Encodes the value to the string form used by the producer's log groups.
    ///
    /// Rules:
    /// - `string` is written verbatim (no JSON quoting).
    /// - Integers are locale-independent decimal text.
    /// - `double` must be finite; NaN/Infinity throw. The representation is
    ///   locale-independent (Swift `String(Double)` always uses `.`).
    /// - `bool` is lowercase `true`/`false`; `null` is the string `null`.
    /// - Collections are compact JSON (no whitespace); dictionary keys are
    ///   sorted for deterministic output.
    /// - `utf8Data` is decoded as UTF-8 text; invalid UTF-8 throws.
    internal func encodedString() throws -> String {
        try encode(remainingDepth: LogValue.maxNestingDepth)
    }

    /// Validates the value without producing the encoded string.
    internal func validate() throws {
        try validate(remainingDepth: LogValue.maxNestingDepth)
    }

    // MARK: - Encoding internals

    private func encode(remainingDepth: Int) throws -> String {
        switch self {
        case .string(let value):
            return value
        case .signedInt(let value):
            return String(value)
        case .unsignedInt(let value):
            return String(value)
        case .double(let value):
            guard value.isFinite else { throw LogValueEncodingError.nonFiniteDouble }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let values):
            guard remainingDepth > 0 else { throw LogValueEncodingError.nestingDepthExceeded }
            let parts = try values.map { try $0.encode(remainingDepth: remainingDepth - 1) }
            return "[" + parts.joined(separator: ",") + "]"
        case .dictionary(let dict):
            guard remainingDepth > 0 else { throw LogValueEncodingError.nestingDepthExceeded }
            let parts = try dict.keys.sorted().map { key -> String in
                let encodedValue = try dict[key]!.encode(remainingDepth: remainingDepth - 1)
                return LogValue.encodeJSONString(key) + ":" + encodedValue
            }
            return "{" + parts.joined(separator: ",") + "}"
        case .utf8Data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw LogValueEncodingError.invalidUTF8Data
            }
            return text
        }
    }

    private func validate(remainingDepth: Int) throws {
        switch self {
        case .double(let value):
            guard value.isFinite else { throw LogValueEncodingError.nonFiniteDouble }
        case .utf8Data(let data):
            guard String(data: data, encoding: .utf8) != nil else {
                throw LogValueEncodingError.invalidUTF8Data
            }
        case .array(let values):
            guard remainingDepth > 0 else { throw LogValueEncodingError.nestingDepthExceeded }
            for value in values {
                try value.validate(remainingDepth: remainingDepth - 1)
            }
        case .dictionary(let dict):
            guard remainingDepth > 0 else { throw LogValueEncodingError.nestingDepthExceeded }
            for value in dict.values {
                try value.validate(remainingDepth: remainingDepth - 1)
            }
        case .string, .signedInt, .unsignedInt, .bool, .null:
            break
        }
    }

    /// Escapes a string as a compact JSON string literal, including the quotes.
    private static func encodeJSONString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out.append("\\\"")
            case "\\":
                out.append("\\\\")
            case "\u{8}":
                out.append("\\b")
            case "\u{c}":
                out.append("\\f")
            case "\n":
                out.append("\\n")
            case "\r":
                out.append("\\r")
            case "\t":
                out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.append(contentsOf: String(scalar))
                }
            }
        }
        out.append("\"")
        return out
    }
}
