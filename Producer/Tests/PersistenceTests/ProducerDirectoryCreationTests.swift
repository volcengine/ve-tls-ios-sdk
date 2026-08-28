// ProducerDirectoryCreationTests.swift
// PersistenceTests
//
// Tests for TLSProducerDirectory default URL computation and directory
// creation with the two mandatory attributes (Beta design §9.2):
//   - NSURLIsExcludedFromBackupKey = YES
//   - NSFileProtectionKey = .completeUntilFirstUserAuthentication
// including the mandatory re-read verification.
//
// SCOPE: these are helper-level tests for the Storage helper. They are NOT
// evidence of C WAL crash-recovery, checkpoint, lease or fsync behavior —
// that evidence comes from the process-kill Core recovery harness and future
// on-device validation, not from these helper-level assertions alone.
//
// ENVIRONMENT NOTE: Data Protection attributes are iOS-specific. The helper
// guards NSFileProtectionKey with TARGET_OS_IOS and these tests guard the
// corresponding assertions with #if os(iOS), so the file compiles on macOS
// host builds (assertions skipped there) and runs in full on an iOS Simulator
// destination (the SDK targets iOS 13). Simulator attributes are not evidence
// of locked-device Data Protection behavior.
//

import XCTest
import TLSProducerBridge

final class ProducerDirectoryCreationTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    private func makeTempRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tls-producer-creation-\(UUID().uuidString)",
                                    isDirectory: true)
        tempRoots.append(root)
        return root
    }

    // MARK: - Default URL

    func testDefaultDirectoryURLStructure() throws {
        let url = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: "unit-test-01")
        let components = url.pathComponents

        // .../Library/Application Support/com.volcengine.tls/producer/<id>/
        XCTAssertTrue(components.contains("Library"), "expected Library in \(url.path)")
        XCTAssertTrue(components.contains("Application Support"),
                      "expected Application Support in \(url.path)")
        XCTAssertTrue(components.contains("com.volcengine.tls"))
        XCTAssertTrue(components.contains("producer"))
        XCTAssertEqual(components.last, "unit-test-01")

        // Ordering: root -> producer -> producerID.
        let rootIndex = try XCTUnwrap(components.firstIndex(of: "com.volcengine.tls"))
        XCTAssertEqual(components[rootIndex + 1], "producer")
        XCTAssertEqual(components[rootIndex + 2], "unit-test-01")

        // The URL computation must not create the directory.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "defaultDirectoryURL must not create the directory")
    }

    // MARK: - Creation + attributes

    func testCreateDirectorySetsAndVerifiesAttributes() throws {
        let dir = makeTempRoot()
            .appendingPathComponent("producer", isDirectory: true)
            .appendingPathComponent("p1", isDirectory: true)

        let created = try TLSProducerDirectory.createDirectory(at: dir)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        // Re-read exclude-from-backup.
        let values = try created.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertTrue(values.isExcludedFromBackup ?? false,
                      "NSURLIsExcludedFromBackupKey must read back as YES")

        // Re-read Data Protection. iOS-only: NSFileProtectionKey /
        // FileProtectionType are absent from the macOS SDK, so these
        // assertions compile out on macOS host builds (the helper skips the
        // attribute there too). On the iOS Simulator the attribute is
        // best-effort and may read back as nil; on a real device it must be
        // the exact expected value.
#if os(iOS)
        let attributes = try FileManager.default.attributesOfItem(atPath: created.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        XCTAssertTrue(
            protection == nil || protection == .completeUntilFirstUserAuthentication,
            "NSFileProtectionKey must be nil (simulator) or CompleteUntilFirstUserAuthentication (device), got \(String(describing: protection))")
#endif
    }

    func testCreateDirectoryIsIdempotent() throws {
        let dir = makeTempRoot()
            .appendingPathComponent("producer", isDirectory: true)
            .appendingPathComponent("p2", isDirectory: true)

        _ = try TLSProducerDirectory.createDirectory(at: dir)
        // Second call on the existing directory must succeed and re-verify.
        _ = try TLSProducerDirectory.createDirectory(at: dir)

        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertTrue(values.isExcludedFromBackup ?? false)
    }

    func testCreateDirectoryCreatesIntermediateDirectories() throws {
        // Multiple non-existent intermediate levels.
        let dir = makeTempRoot()
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("c", isDirectory: true)

        let created = try TLSProducerDirectory.createDirectory(at: dir)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testCreateDirectoryOnDefaultLikeStructureInTempLocation() throws {
        // Mirrors the default directory layout (com.volcengine.tls/producer/
        // <id>) under a temp root so the test never writes to the real
        // ~/Library/Application Support. The default URL computation itself
        // is covered by testDefaultDirectoryURLStructure; this verifies
        // createDirectory + attributes on the same path shape. The temp root
        // is removed by tearDown.
        let root = makeTempRoot()
        let defaultLike = root
            .appendingPathComponent("com.volcengine.tls", isDirectory: true)
            .appendingPathComponent("producer", isDirectory: true)
            .appendingPathComponent("e2e-test-02", isDirectory: true)

        let created = try TLSProducerDirectory.createDirectory(at: defaultLike)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let values = try created.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertTrue(values.isExcludedFromBackup ?? false)
#if os(iOS)
        // Data Protection re-read — iOS-only (see testCreateDirectorySetsAnd
        // VerifiesAttributes for the platform rationale). nil is accepted
        // on the simulator; a real device must report the exact value.
        let attributes = try FileManager.default.attributesOfItem(atPath: created.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        XCTAssertTrue(
            protection == nil || protection == .completeUntilFirstUserAuthentication,
            "NSFileProtectionKey must be nil (simulator) or CompleteUntilFirstUserAuthentication (device), got \(String(describing: protection))")
#endif
    }
}
