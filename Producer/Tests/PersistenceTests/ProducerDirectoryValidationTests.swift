// ProducerDirectoryValidationTests.swift
// PersistenceTests
//
// Tests for TLSProducerDirectory producerID validation (Beta design §9.2:
// non-empty, [A-Za-z0-9._-] only, at most 64 UTF-8 bytes).
//
// SCOPE: these are helper-level tests for the Storage helper. They are NOT
// evidence of C WAL crash-recovery, checkpoint, lease or fsync behavior —
// that evidence comes from the process-kill Core recovery harness and future
// on-device validation, not from these helper-level assertions alone.
//

import XCTest
import TLSProducerBridge

final class ProducerDirectoryValidationTests: XCTestCase {

    // MARK: - Valid

    func testValidProducerIDs() {
        XCTAssertNoThrow(try TLSProducerDirectory.validateProducerID("a"))
        XCTAssertNoThrow(try TLSProducerDirectory.validateProducerID("abc"))
        XCTAssertNoThrow(try TLSProducerDirectory.validateProducerID("ABC123"))
        XCTAssertNoThrow(try TLSProducerDirectory.validateProducerID("a.b-c_d"))
        XCTAssertNoThrow(try TLSProducerDirectory.validateProducerID("0"))
        // Every allowed character class (64 chars == 64 bytes, the exact
        // upper bound; '-' is already covered by "a.b-c_d" above).
        XCTAssertNoThrow(
            try TLSProducerDirectory.validateProducerID(
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._"))
    }

    func testValidProducerIDAt64UTF8Bytes() {
        // 64 ASCII characters == 64 UTF-8 bytes: the exact upper bound.
        let id = String(repeating: "a", count: 64)
        XCTAssertNoThrow(try TLSProducerDirectory.validateProducerID(id))
    }

    func testMultibyteCharactersRejectedRegardlessOfByteLength() {
        // The charset rule ([A-Za-z0-9._-] only) takes precedence over the
        // byte-length rule. "你" is 3 UTF-8 bytes; 21 * 3 = 63 bytes <= 64,
        // but the character is outside the allowed charset, so it MUST be
        // rejected. (The 64/65-byte boundary itself is covered by the pure
        // ASCII cases above and below.)
        let id = String(repeating: "你", count: 21)
        XCTAssertThrowsError(try TLSProducerDirectory.validateProducerID(id)) { error in
            self.assertInvalidProducerID(error)
        }
    }

    // MARK: - Invalid

    func testEmptyProducerIDRejected() {
        XCTAssertThrowsError(try TLSProducerDirectory.validateProducerID("")) { error in
            self.assertInvalidProducerID(error)
        }
    }

    func testIllegalCharactersRejected() {
        let illegal = [
            "producer/id",      // path separator
            "producer id",      // space
            "producer:id",      // colon
            "producer#id",      // fragment marker
            "id@example",       // @
            "id+tag",           // +
            "id=tag",           // =
            "idéntité",         // Unicode letter (é)
            "生产者",            // CJK
            "id\ttab",          // control character
        ]
        for candidate in illegal {
            XCTAssertThrowsError(try TLSProducerDirectory.validateProducerID(candidate)) { error in
                self.assertInvalidProducerID(error)
            }
        }
    }

    func testSpecialPathComponentsRejected() {
        // "." and ".." pass the character set but would collapse/escape the
        // producer root when appended as a path component.
        XCTAssertThrowsError(try TLSProducerDirectory.validateProducerID(".")) { error in
            self.assertInvalidProducerID(error)
        }
        XCTAssertThrowsError(try TLSProducerDirectory.validateProducerID("..")) { error in
            self.assertInvalidProducerID(error)
        }
    }

    func testOverlongProducerIDRejected() {
        // 65 ASCII characters == 65 UTF-8 bytes: over the bound.
        XCTAssertThrowsError(
            try TLSProducerDirectory.validateProducerID(String(repeating: "a", count: 65))
        ) { error in
            self.assertInvalidProducerID(error)
        }
        // Note: a multibyte "overlong" case (e.g. "你" x 22 = 66 bytes) is
        // rejected by the CHARSET check before the length check is reached,
        // so it does not test the length boundary. Charset rejection of
        // multibyte IDs is covered by
        // testMultibyteCharactersRejectedRegardlessOfByteLength.
    }

    func testInvalidProducerIDRejectsDefaultDirectoryURL() {
        XCTAssertThrowsError(
            try TLSProducerDirectory.defaultDirectoryURL(forProducerID: "bad/id")
        ) { error in
            self.assertInvalidProducerID(error)
        }
    }

    // MARK: - Helpers

    private func assertInvalidProducerID(_ error: Error,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        let nsError = error as NSError
        XCTAssertEqual(nsError.domain,
                       TLSProducerDirectoryErrorDomain,
                       "wrong error domain",
                       file: file, line: line)
        XCTAssertEqual(nsError.code,
                       TLSProducerDirectoryErrorCode.invalidProducerID.rawValue,
                       "wrong error code",
                       file: file, line: line)
    }
}
