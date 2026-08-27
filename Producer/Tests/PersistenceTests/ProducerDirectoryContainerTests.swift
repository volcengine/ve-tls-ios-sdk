// ProducerDirectoryContainerTests.swift
// PersistenceTests
//
// Tests for TLSProducerDirectory container validation (Beta design §9.2:
// custom directories must stay inside the App container). The container base
// is injected so the tests are deterministic and do not depend on the real
// NSHomeDirectory() layout.
//
// SCOPE: these are helper-level tests for the Storage helper. They are NOT
// evidence of C WAL crash-recovery, checkpoint, lease or fsync behavior —
// that evidence is L4 (macOS Core crash harness + on-device XCUITest) and is
// pending the frozen C Core and a macOS/Xcode toolchain (ledger §4).
//

import XCTest
import TLSProducerBridge

final class ProducerDirectoryContainerTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    private func makeTempRoot(named name: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        tempRoots.append(root)
        return root
    }

    // MARK: - Injected base

    func testURLInsideContainerAccepted() {
        let base = makeTempRoot(named: "tls-container-\(UUID().uuidString)")
        let candidate = base
            .appendingPathComponent("producer", isDirectory: true)
            .appendingPathComponent("p1", isDirectory: true)
        XCTAssertTrue(TLSProducerDirectory.isURL(candidate, insideContainerBaseURL: base))
    }

    func testURLExactlyAtContainerRootAccepted() {
        let base = makeTempRoot(named: "tls-container-\(UUID().uuidString)")
        XCTAssertTrue(TLSProducerDirectory.isURL(base, insideContainerBaseURL: base))
    }

    func testURLWithStandardizedPathInsideContainerAccepted() {
        let base = makeTempRoot(named: "tls-container-\(UUID().uuidString)")
        // "a/../b" standardizes to "b" — still inside the container.
        let candidate = base
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
        XCTAssertTrue(TLSProducerDirectory.isURL(candidate, insideContainerBaseURL: base))
    }

    func testSiblingStringPrefixRejected() {
        // Path-COMPONENT boundary: "container-abc-evil" must not pass for a
        // container named "container-abc" even though the string prefix matches.
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tls-container-abc", isDirectory: true)
        let sibling = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tls-container-abc-evil", isDirectory: true)
            .appendingPathComponent("x", isDirectory: true)
        XCTAssertFalse(TLSProducerDirectory.isURL(sibling, insideContainerBaseURL: base))
    }

    func testURLOutsideContainerRejected() {
        let base = makeTempRoot(named: "tls-container-\(UUID().uuidString)")
        let outside = makeTempRoot(named: "tls-other-\(UUID().uuidString)")
        XCTAssertFalse(TLSProducerDirectory.isURL(outside, insideContainerBaseURL: base))
    }

    func testPathTraversalEscapingContainerRejected() {
        let base = makeTempRoot(named: "tls-container-\(UUID().uuidString)")
        // "base/../../escape" standardizes outside the container.
        let escaping = base
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("escape", isDirectory: true)
        XCTAssertFalse(TLSProducerDirectory.isURL(escaping, insideContainerBaseURL: base))
    }

    func testNonFileURLRejected() {
        let base = makeTempRoot(named: "tls-container-\(UUID().uuidString)")
        let httpURL = URL(string: "http://example.com/producer/p1")!
        XCTAssertFalse(TLSProducerDirectory.isURL(httpURL, insideContainerBaseURL: base))
    }

    func testSymlinkEscapingContainerRejected() throws {
        // A symlink inside the container that resolves outside must be
        // rejected (URLByResolvingSymlinksInPath must be applied to the
        // candidate, not just a string-prefix check).
        let base = makeTempRoot(named: "tls-container-\(UUID().uuidString)")
        let outside = makeTempRoot(named: "tls-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside,
                                                withIntermediateDirectories: true)

        let link = base.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: outside)

        // The symlink itself sits inside the container but resolves outside.
        XCTAssertFalse(TLSProducerDirectory.isURL(link, insideContainerBaseURL: base))
        // A path traversing the symlink also resolves outside.
        let throughLink = link.appendingPathComponent("data", isDirectory: true)
        XCTAssertFalse(TLSProducerDirectory.isURL(throughLink, insideContainerBaseURL: base))
    }

    // MARK: - Default base (nil == NSHomeDirectory)

    func testDefaultBaseIsHomeDirectory() {
        // A URL under the real home directory is inside the default container.
        let homeSubdirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        XCTAssertTrue(
            TLSProducerDirectory.isURL(homeSubdirectory, insideContainerBaseURL: nil))

        // A system path outside the home directory is rejected.
        let systemPath = URL(fileURLWithPath: "/private/etc/hosts")
        XCTAssertFalse(
            TLSProducerDirectory.isURL(systemPath, insideContainerBaseURL: nil))
    }
}
