// LifecycleManagerTests.swift
// PersistenceTests
//
// Tests for TLSLifecycleManager (Beta design §9.3):
//   - App process: didEnterBackground -> flush + background task request with
//     an expirationHandler that ends the task immediately;
//     willEnterForeground -> wake handler;
//   - App Extension process (extensionCheck == YES): no notifications
//     registered, no UIApplication calls, all no-op;
//   - dealloc removes observers and ends outstanding tasks.
//
// The UIApplication surface is faked via RecordingLifecycleHost (the
// TLSLifecycleHost protocol), so no real UIApplication/UIKit is touched.
//
// SCOPE: these are helper-level tests for the Lifecycle helper. They are NOT
// evidence of C WAL crash-recovery, checkpoint, lease or fsync behavior —
// that evidence is L4 (macOS Core crash harness + on-device XCUITest) and is
// pending the frozen C Core and a macOS/Xcode toolchain (ledger §4).
//

import XCTest
import TLSProducerBridge

/// Fake TLSLifecycleHost recording begin/end calls and retaining the
/// expiration handler so tests can fire it manually.
final class RecordingLifecycleHost: NSObject, TLSLifecycleHost {

    struct BeginCall {
        let name: String
        let expirationHandler: (() -> Void)?
    }

    private(set) var beginCalls: [BeginCall] = []
    private(set) var endCalls: [UInt] = []

    func beginBackgroundTask(withName name: String,
                             expirationHandler: (() -> Void)?) -> UInt {
        let identifier = UInt(beginCalls.count + 1)
        beginCalls.append(BeginCall(name: name, expirationHandler: expirationHandler))
        return identifier
    }

    func endBackgroundTask(_ identifier: UInt) {
        endCalls.append(identifier)
    }
}

final class LifecycleManagerTests: XCTestCase {

    // MARK: - Extension process

    func testExtensionProcessRegistersNoObservers() {
        var flushCount = 0
        var wakeCount = 0
        let host = RecordingLifecycleHost()
        let manager = TLSLifecycleManager(
            flushHandler: { flushCount += 1 },
            wakeHandler: { wakeCount += 1 },
            host: host,
            extensionCheck: { true })

        NotificationCenter.default.post(
            name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)
        NotificationCenter.default.post(
            name: TLSLifecycleWillEnterForegroundNotificationName, object: nil)

        XCTAssertEqual(flushCount, 0, "extension process must not flush")
        XCTAssertEqual(wakeCount, 0, "extension process must not wake")
        XCTAssertTrue(host.beginCalls.isEmpty,
                      "extension process must not request background tasks")
        XCTAssertTrue(host.endCalls.isEmpty)
        _ = manager
    }

    // MARK: - App process: background

    func testBackgroundNotificationTriggersFlushAndBackgroundTask() {
        var flushCount = 0
        let host = RecordingLifecycleHost()
        let manager = TLSLifecycleManager(
            flushHandler: { flushCount += 1 },
            wakeHandler: {},
            host: host,
            extensionCheck: { false })

        NotificationCenter.default.post(
            name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)

        XCTAssertEqual(flushCount, 1)
        XCTAssertEqual(host.beginCalls.count, 1)
        XCTAssertEqual(host.beginCalls.first?.name,
                       "com.volcengine.tls.producer.flush")
        XCTAssertNotNil(host.beginCalls.first?.expirationHandler,
                        "an expiration handler must be provided")
        XCTAssertTrue(host.endCalls.isEmpty,
                      "the task stays open until expiration/foreground")
        _ = manager
    }

    func testExpirationHandlerEndsTaskImmediately() {
        let host = RecordingLifecycleHost()
        let manager = TLSLifecycleManager(
            flushHandler: {},
            wakeHandler: {},
            host: host,
            extensionCheck: { false })

        NotificationCenter.default.post(
            name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)
        XCTAssertEqual(host.beginCalls.count, 1)

        // Fire the system expiration: the task must be ended immediately
        // (no continued blocking of system suspension, design §9.3).
        host.beginCalls[0].expirationHandler?()

        XCTAssertEqual(host.endCalls, [1],
                       "expiration must end the exact task that was begun")
        _ = manager
    }

    func testRepeatedBackgroundEndsPreviousTaskBeforeBeginningNewOne() {
        let host = RecordingLifecycleHost()
        let manager = TLSLifecycleManager(
            flushHandler: {},
            wakeHandler: {},
            host: host,
            extensionCheck: { false })
        let center = NotificationCenter.default

        center.post(name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)
        center.post(name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)

        XCTAssertEqual(host.beginCalls.count, 2)
        XCTAssertEqual(host.endCalls, [1],
                       "the stale task must be ended before a new one begins")
        _ = manager
    }

    // MARK: - App process: foreground

    func testForegroundNotificationTriggersWake() {
        var wakeCount = 0
        let host = RecordingLifecycleHost()
        let manager = TLSLifecycleManager(
            flushHandler: {},
            wakeHandler: { wakeCount += 1 },
            host: host,
            extensionCheck: { false })

        NotificationCenter.default.post(
            name: TLSLifecycleWillEnterForegroundNotificationName, object: nil)

        XCTAssertEqual(wakeCount, 1)
        _ = manager
    }

    func testForegroundEndsOutstandingBackgroundTask() {
        let host = RecordingLifecycleHost()
        let manager = TLSLifecycleManager(
            flushHandler: {},
            wakeHandler: {},
            host: host,
            extensionCheck: { false })
        let center = NotificationCenter.default

        center.post(name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)
        XCTAssertEqual(host.beginCalls.count, 1)
        XCTAssertTrue(host.endCalls.isEmpty)

        center.post(name: TLSLifecycleWillEnterForegroundNotificationName, object: nil)
        XCTAssertEqual(host.endCalls, [1],
                       "returning to foreground must release the wrap-up task")
        _ = manager
    }

    // MARK: - Host absence

    func testNilHostDisablesBackgroundTasksButKeepsObservers() {
        var flushCount = 0
        var wakeCount = 0
        let manager = TLSLifecycleManager(
            flushHandler: { flushCount += 1 },
            wakeHandler: { wakeCount += 1 },
            host: nil,
            extensionCheck: { false })

        NotificationCenter.default.post(
            name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)
        NotificationCenter.default.post(
            name: TLSLifecycleWillEnterForegroundNotificationName, object: nil)

        XCTAssertEqual(flushCount, 1, "flush must still run without a host")
        XCTAssertEqual(wakeCount, 1, "wake must still run without a host")
        _ = manager
    }

    // MARK: - Teardown

    func testDeallocRemovesObserversAndEndsOutstandingTask() {
        var flushCount = 0
        let host = RecordingLifecycleHost()
        var manager: TLSLifecycleManager? = TLSLifecycleManager(
            flushHandler: { flushCount += 1 },
            wakeHandler: {},
            host: host,
            extensionCheck: { false })
        let center = NotificationCenter.default

        center.post(name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)
        XCTAssertEqual(flushCount, 1)
        XCTAssertEqual(host.beginCalls.count, 1)
        XCTAssertTrue(host.endCalls.isEmpty)

        // Release the manager. dealloc must remove observers (otherwise the
        // next post would message a deallocated object and crash) and end the
        // outstanding background task.
        manager = nil
        XCTAssertEqual(host.endCalls, [1])

        // Must not crash, and must not invoke the released handler.
        center.post(name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)
        center.post(name: TLSLifecycleWillEnterForegroundNotificationName, object: nil)
        XCTAssertEqual(flushCount, 1, "no handler calls after dealloc")
    }

    func testExpirationHandlerAfterDeallocDoesNotCrash() {
        // The system may call the saved expiration handler after the manager
        // has been deallocated (e.g. the background task is still open when
        // the Producer is released). The handler captures weakSelf, so it
        // must be a no-op: no crash, no additional host calls.
        let host = RecordingLifecycleHost()
        var manager: TLSLifecycleManager? = TLSLifecycleManager(
            flushHandler: {},
            wakeHandler: {},
            host: host,
            extensionCheck: { false })

        NotificationCenter.default.post(
            name: TLSLifecycleDidEnterBackgroundNotificationName, object: nil)
        XCTAssertEqual(host.beginCalls.count, 1)
        let expirationHandler = host.beginCalls[0].expirationHandler
        XCTAssertNotNil(expirationHandler)

        // dealloc ends the task (endCalls == [1]) and releases the handler's
        // strong references; the host still retains the saved block.
        manager = nil
        XCTAssertEqual(host.endCalls, [1])

        // Fire the saved handler after dealloc: must not crash and must not
        // message the host again (weakSelf is nil → no-op).
        expirationHandler?()
        XCTAssertEqual(host.endCalls, [1],
                       "no additional host calls after dealloc")
    }

    // MARK: - Convenience initializer

    func testConvenienceInitializerUsesDefaultExtensionProbe() {
        // The convenience initializer wires the default host (UIApplication
        // via runtime) and the default extension probe (mainBundle
        // infoDictionary[@"NSExtension"]). A unit-test host has no NSExtension
        // entry, so observers are registered. Foreground only: exercising the
        // background path would call the real UIApplication.
        var wakeCount = 0
        let manager = TLSLifecycleManager(
            flushHandler: {},
            wakeHandler: { wakeCount += 1 })

        NotificationCenter.default.post(
            name: TLSLifecycleWillEnterForegroundNotificationName, object: nil)
        XCTAssertEqual(wakeCount, 1)
        _ = manager
    }
}
