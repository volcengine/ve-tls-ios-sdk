//
//  AppDelegate.swift
//  SimulatorRecoveryHarness
//
//  A deliberately small process-level recovery harness.  The companion
//  simctl script starts this app in one of three modes, kills the process
//  after the seed marker is durable, and starts the same installed app again
//  for recovery.  This is not a product sample and it does not contain real
//  credentials.
//

import Foundation
import UIKit
import VolcengineTLSProducer

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    private var runner: SimulatorRecoveryRunner?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let runner = SimulatorRecoveryRunner()
        self.runner = runner
        runner.start()
        return true
    }
}

private enum HarnessMode: String, Sendable {
    case seed
    case recover
    case soak
    case volume
}

private enum PersistenceMode: String, Sendable {
    case disabled
    case memory
    case buffered
    case sync

    var producerPersistence: Persistence {
        switch self {
        case .disabled:
            return .disabled
        case .memory:
            return .memory
        case .buffered:
            return .buffered
        case .sync:
            return .sync
        }
    }
}

private enum NetworkFaultMode: String, Sendable {
    case direct
    case blockBeforeSend = "block-before-send"
    case loseAckAfter200 = "lose-ack-after-200"
}

private enum VolumeProfile: String, CaseIterable, Sendable {
    case defaultLZ4 = "default-lz4"
    case noCompressionCount = "no-compression-count"
    case bufferedHighConcurrency = "buffered-high-concurrency"
    case syncMaxCount = "sync-max-count"
    case hashRouting = "hash-routing"
    case mixedImmediate = "mixed-immediate"
    case complexDataDefault = "complex-data-default"
    case complexDataCustom = "complex-data-custom"
    case hotUpdate = "hot-update"
    case authRetainBulk = "auth-retain-bulk"

    /// Keep the first volume profile names accepted by the design as aliases,
    /// while emitting only the canonical profile name in `VolumeResult`.
    static func parse(_ value: String) -> VolumeProfile? {
        switch value.lowercased() {
        case "no-compression-byte":
            return .noCompressionCount
        case "hash-concurrency":
            return .hashRouting
        case "complex-data":
            return .complexDataCustom
        default:
            return VolumeProfile(rawValue: value.lowercased())
        }
    }

    func accepts(_ persistence: PersistenceMode) -> Bool {
        switch self {
        case .bufferedHighConcurrency:
            return persistence == .buffered
        case .syncMaxCount, .authRetainBulk:
            return persistence == .sync
        case .defaultLZ4, .noCompressionCount, .hashRouting,
             .mixedImmediate, .complexDataDefault, .complexDataCustom,
             .hotUpdate:
            return true
        }
    }
}

private struct VolumeProfileConfiguration: Sendable {
    let batch: BatchConfiguration
    let buffer: BufferConfiguration
    let sendConcurrency: Int
    let compression: Compression
    let payloadBytes: Int
    let metadata: ProducerMetadata
}

private extension VolumeProfile {
    var configuration: VolumeProfileConfiguration {
        let ordinaryMetadata = ProducerMetadata(
            source: "ios-boe-volume",
            fileName: "producer-volume.log",
            tags: [
                "sdk": "ios",
                "suite": "boe-volume",
                "profile": rawValue,
            ])
        let customMetadata = ProducerMetadata(
            source: "iOS-业务-🙂",
            fileName: "业务/volume.log",
            tags: [
                "sdk": "ios",
                "suite": "boe-volume",
                "profile": rawValue,
                "locale": "zh-CN",
            ])

        switch self {
        case .defaultLZ4:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 1_024,
                    maxRawBytes: 1 * 1024 * 1024,
                    linger: 3),
                buffer: BufferConfiguration(
                    maxBytes: 64 * 1024 * 1024,
                    fullPolicy: .reject,
                    blockTimeout: 1),
                sendConcurrency: 1,
                compression: .lz4,
                payloadBytes: 1_024,
                metadata: ordinaryMetadata)
        case .noCompressionCount:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 256,
                    maxRawBytes: 1 * 1024 * 1024,
                    linger: 30),
                buffer: BufferConfiguration(
                    maxBytes: 16 * 1024 * 1024,
                    fullPolicy: .reject,
                    blockTimeout: 1),
                sendConcurrency: 4,
                compression: .disabled,
                payloadBytes: 2_048,
                metadata: ordinaryMetadata)
        case .bufferedHighConcurrency:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 4_096,
                    maxRawBytes: 4 * 1024 * 1024,
                    linger: 90),
                buffer: BufferConfiguration(
                    maxBytes: 128 * 1024 * 1024,
                    fullPolicy: .reject,
                    blockTimeout: 1),
                sendConcurrency: 8,
                compression: .lz4,
                payloadBytes: 512,
                metadata: ordinaryMetadata)
        case .syncMaxCount:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 10_000,
                    maxRawBytes: 19 * 512 * 1024,
                    linger: 90),
                buffer: BufferConfiguration(
                    maxBytes: 256 * 1024 * 1024,
                    fullPolicy: .block,
                    blockTimeout: 1),
                sendConcurrency: 2,
                compression: .disabled,
                payloadBytes: 512,
                metadata: ordinaryMetadata)
        case .hashRouting:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 256,
                    maxRawBytes: 2 * 1024 * 1024,
                    linger: 3),
                buffer: BufferConfiguration(
                    maxBytes: 64 * 1024 * 1024,
                    fullPolicy: .reject,
                    blockTimeout: 1),
                sendConcurrency: 4,
                compression: .lz4,
                payloadBytes: 512,
                metadata: ordinaryMetadata)
        case .mixedImmediate:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 128,
                    maxRawBytes: 512 * 1024,
                    linger: 250 / 1_000),
                buffer: BufferConfiguration(
                    maxBytes: 32 * 1024 * 1024,
                    fullPolicy: .reject,
                    blockTimeout: 1),
                sendConcurrency: 1,
                compression: .lz4,
                payloadBytes: 256,
                metadata: ordinaryMetadata)
        case .complexDataDefault:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 1_024,
                    maxRawBytes: 1 * 1024 * 1024,
                    linger: 3),
                buffer: BufferConfiguration(
                    maxBytes: 64 * 1024 * 1024,
                    fullPolicy: .reject,
                    blockTimeout: 1),
                sendConcurrency: 1,
                compression: .lz4,
                payloadBytes: 512,
                metadata: ProducerMetadata())
        case .complexDataCustom:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 1_024,
                    maxRawBytes: 1 * 1024 * 1024,
                    linger: 3),
                buffer: BufferConfiguration(
                    maxBytes: 64 * 1024 * 1024,
                    fullPolicy: .reject,
                    blockTimeout: 1),
                sendConcurrency: 1,
                compression: .lz4,
                payloadBytes: 512,
                metadata: customMetadata)
        case .hotUpdate:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 512,
                    maxRawBytes: 2 * 1024 * 1024,
                    linger: 1),
                buffer: BufferConfiguration(
                    maxBytes: 64 * 1024 * 1024,
                    fullPolicy: .reject,
                    blockTimeout: 1),
                sendConcurrency: 2,
                compression: .lz4,
                payloadBytes: 768,
                metadata: ordinaryMetadata)
        case .authRetainBulk:
            return VolumeProfileConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 1_024,
                    maxRawBytes: 4 * 1024 * 1024,
                    linger: 3),
                buffer: BufferConfiguration(
                    maxBytes: 128 * 1024 * 1024,
                    fullPolicy: .block,
                    blockTimeout: 1),
                sendConcurrency: 2,
                compression: .lz4,
                payloadBytes: 768,
                metadata: ordinaryMetadata)
        }
    }
}

private struct GeneratedEvent: Sendable {
    let logEvent: LogEvent
    /// Exact public field bytes: the UTF-8 byte count of every key plus its
    /// encoded value. This is the expected raw-byte total for the volume run.
    let rawFieldBytes: Int
}

/// A shared actor clock spaces all admission tasks against one aggregate rate.
/// The slot is reserved before the await, so concurrent workers cannot each
/// observe the same timestamp and burst at the configured rate independently.
private actor VolumeRateLimiter {
    private let intervalNanoseconds: UInt64?
    private var nextSlot: UInt64?

    init(targetLogsPerSecond: Double?) {
        guard let targetLogsPerSecond,
              targetLogsPerSecond.isFinite,
              targetLogsPerSecond > 0 else {
            intervalNanoseconds = nil
            nextSlot = nil
            return
        }

        let interval = 1_000_000_000.0 / targetLogsPerSecond
        if interval >= Double(UInt64.max) {
            intervalNanoseconds = UInt64.max
        } else {
            intervalNanoseconds = max(1, UInt64(interval.rounded(.up)))
        }
        nextSlot = nil
    }

    func waitForSlot() async {
        guard let intervalNanoseconds else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let slot = max(now, nextSlot ?? now)
        let (next, overflow) = slot.addingReportingOverflow(intervalNanoseconds)
        nextSlot = overflow ? UInt64.max : next
        if slot > now {
            try? await Task.sleep(nanoseconds: slot - now)
        }
    }
}

private struct HarnessInput: Sendable {
    let mode: HarnessMode
    let endpoint: String
    let region: String
    let projectID: String
    let topicID: String
    let persistence: PersistenceMode
    let producerID: String
    let runID: String
    let scenario: String
    let networkFaultMode: NetworkFaultMode
    let accessKeyID: String?
    let accessKeySecret: String?
    let securityToken: String?
    let initialAccessKeyID: String?
    let initialAccessKeySecret: String?
    let initialSecurityToken: String?
    let unauthorizedPolicy: UnauthorizedPolicy
    let seedCount: Int?
    let recoveryTimeout: TimeInterval
    let soakDuration: TimeInterval?
    let soakInterval: TimeInterval?
    let volumeProfile: VolumeProfile?
    let targetLogsPerSecond: Double?

    init() throws {
        let modeText = HarnessInput.argumentOrEnvironment(
            argument: "mode",
            environment: "TLS_SIMULATOR_MODE")
        guard let modeText,
              let mode = HarnessMode(rawValue: modeText.lowercased()) else {
            throw HarnessInputError.missingOrInvalid("mode")
        }

        let endpoint = try HarnessInput.required(
            argument: "endpoint",
            environment: "TLS_SIMULATOR_ENDPOINT")
        let region = try HarnessInput.required(
            argument: "region",
            environment: "TLS_SIMULATOR_REGION")
        let projectID = try HarnessInput.required(
            argument: "project-id",
            environment: "TLS_SIMULATOR_PROJECT_ID")
        let topicID = try HarnessInput.required(
            argument: "topic-id",
            environment: "TLS_SIMULATOR_TOPIC_ID")
        let persistenceText = try HarnessInput.required(
            argument: "persistence",
            environment: "TLS_SIMULATOR_PERSISTENCE")
        guard let persistence = PersistenceMode(rawValue: persistenceText.lowercased()) else {
            throw HarnessInputError.missingOrInvalid("persistence")
        }
        let producerID = try HarnessInput.required(
            argument: "producer-id",
            environment: "TLS_SIMULATOR_PRODUCER_ID")
        let runID = try HarnessInput.required(
            argument: "run-id",
            environment: "TLS_SIMULATOR_RUN_ID")
        let scenario = HarnessInput.argumentOrEnvironment(
            argument: "scenario",
            environment: "TLS_SIMULATOR_SCENARIO") ?? "simulator_recovery"
        let networkFaultText = HarnessInput.argumentOrEnvironment(
            argument: "network-fault",
            environment: "TLS_SIMULATOR_NETWORK_FAULT") ?? "direct"
        guard let networkFaultMode = NetworkFaultMode(
            rawValue: networkFaultText.lowercased()) else {
            throw HarnessInputError.missingOrInvalid("network-fault")
        }
        let accessKeyID = ProcessInfo.processInfo.environment[
            "TLS_SIMULATOR_ACCESS_KEY_ID"]
        let accessKeySecret = ProcessInfo.processInfo.environment[
            "TLS_SIMULATOR_ACCESS_KEY_SECRET"]
        let securityToken = ProcessInfo.processInfo.environment[
            "TLS_SIMULATOR_SECURITY_TOKEN"]
        if (accessKeyID == nil) != (accessKeySecret == nil) {
            throw HarnessInputError.missingOrInvalid("credentials")
        }
        let initialAccessKeyID = ProcessInfo.processInfo.environment[
            "TLS_SIMULATOR_INITIAL_ACCESS_KEY_ID"]
        let initialAccessKeySecret = ProcessInfo.processInfo.environment[
            "TLS_SIMULATOR_INITIAL_ACCESS_KEY_SECRET"]
        let initialSecurityToken = ProcessInfo.processInfo.environment[
            "TLS_SIMULATOR_INITIAL_SECURITY_TOKEN"]
        if (initialAccessKeyID == nil) != (initialAccessKeySecret == nil) ||
            (initialSecurityToken != nil && initialAccessKeyID == nil) {
            throw HarnessInputError.missingOrInvalid("initial-credentials")
        }
        let unauthorizedPolicyText = HarnessInput.argumentOrEnvironment(
            argument: "unauthorized-policy",
            environment: "TLS_SIMULATOR_UNAUTHORIZED_POLICY") ?? "retain"
        let unauthorizedPolicy: UnauthorizedPolicy
        switch unauthorizedPolicyText.lowercased() {
        case "retain":
            unauthorizedPolicy = .retain
        case "drop":
            unauthorizedPolicy = .drop
        default:
            throw HarnessInputError.missingOrInvalid("unauthorized-policy")
        }

        let seedCount: Int?
        if let rawSeedCount = HarnessInput.argumentOrEnvironment(
            argument: "seed-count",
            environment: "TLS_SIMULATOR_SEED_COUNT") {
            guard let parsed = Int(rawSeedCount), parsed > 0 else {
                throw HarnessInputError.missingOrInvalid("seed-count")
            }
            seedCount = parsed
        } else {
            seedCount = nil
        }
        if (mode == .seed || mode == .volume) && seedCount == nil {
            throw HarnessInputError.missingOrInvalid("seed-count")
        }

        let recoveryTimeout = try HarnessInput.positiveDouble(
            argument: "recovery-timeout",
            environment: "TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS",
            defaultValue: mode == .volume ? 600 : 120)

        let soakDuration: TimeInterval?
        let soakInterval: TimeInterval?
        if mode == .soak {
            soakDuration = try HarnessInput.positiveDouble(
                argument: "soak-duration",
                environment: "TLS_SIMULATOR_SOAK_DURATION_SECONDS",
                defaultValue: nil)
            soakInterval = try HarnessInput.positiveDouble(
                argument: "soak-interval-ms",
                environment: "TLS_SIMULATOR_SOAK_INTERVAL_MS",
                defaultValue: nil) / 1_000
        } else {
            soakDuration = nil
            soakInterval = nil
        }

        guard !runID.contains("\0"), runID.utf8.count <= 128 else {
            throw HarnessInputError.missingOrInvalid("run-id")
        }
        guard !scenario.isEmpty, !scenario.contains("\0"), scenario.utf8.count <= 128 else {
            throw HarnessInputError.missingOrInvalid("scenario")
        }
        if mode != .seed && networkFaultMode != .direct {
            throw HarnessInputError.missingOrInvalid("recover-network-fault")
        }

        let volumeProfile: VolumeProfile?
        if mode == .volume {
            guard let profileText = HarnessInput.argumentOrEnvironment(
                argument: "volume-profile",
                environment: "TLS_SIMULATOR_VOLUME_PROFILE"),
                  let profile = VolumeProfile.parse(profileText) else {
                throw HarnessInputError.missingOrInvalid("volume-profile")
            }
            volumeProfile = profile
        } else {
            volumeProfile = nil
        }

        let targetLogsPerSecond: Double?
        if mode == .volume,
           let rawRate = HarnessInput.argumentOrEnvironment(
            argument: "target-logs-per-second",
            environment: "TLS_SIMULATOR_TARGET_LOGS_PER_SECOND") {
            guard let rate = Double(rawRate), rate.isFinite, rate > 0 else {
                throw HarnessInputError.missingOrInvalid("target-logs-per-second")
            }
            targetLogsPerSecond = rate
        } else {
            targetLogsPerSecond = nil
        }

        self.mode = mode
        self.endpoint = endpoint
        self.region = region
        self.projectID = projectID
        self.topicID = topicID
        self.persistence = persistence
        self.producerID = producerID
        self.runID = runID
        self.scenario = scenario
        self.networkFaultMode = networkFaultMode
        self.accessKeyID = accessKeyID
        self.accessKeySecret = accessKeySecret
        self.securityToken = securityToken
        self.initialAccessKeyID = initialAccessKeyID
        self.initialAccessKeySecret = initialAccessKeySecret
        self.initialSecurityToken = initialSecurityToken
        self.unauthorizedPolicy = unauthorizedPolicy
        self.seedCount = seedCount
        self.recoveryTimeout = recoveryTimeout
        self.soakDuration = soakDuration
        self.soakInterval = soakInterval
        self.volumeProfile = volumeProfile
        self.targetLogsPerSecond = targetLogsPerSecond
    }

    private static func required(argument: String, environment: String) throws -> String {
        guard let value = argumentOrEnvironment(argument: argument, environment: environment),
              !value.isEmpty else {
            throw HarnessInputError.missingOrInvalid(environment)
        }
        return value
    }

    private static func positiveDouble(
        argument: String,
        environment: String,
        defaultValue: Double?
    ) throws -> Double {
        guard let raw = argumentOrEnvironment(argument: argument, environment: environment) else {
            if let defaultValue {
                return defaultValue
            }
            throw HarnessInputError.missingOrInvalid(environment)
        }
        guard let value = Double(raw), value.isFinite, value > 0 else {
            throw HarnessInputError.missingOrInvalid(environment)
        }
        return value
    }

    private static func argumentOrEnvironment(argument: String, environment: String) -> String? {
        let prefix = "--\(argument)="
        let arguments = CommandLine.arguments
        if let inline = arguments.dropFirst().first(where: { $0.hasPrefix(prefix) }) {
            return String(inline.dropFirst(prefix.count))
        }
        if let index = arguments.dropFirst().firstIndex(of: "--\(argument)"),
           arguments.index(after: index) < arguments.endIndex {
            return arguments[arguments.index(after: index)]
        }
        return ProcessInfo.processInfo.environment[environment]
    }
}

private enum HarnessInputError: Error {
    case missingOrInvalid(String)

    var code: String {
        switch self {
        case .missingOrInvalid(let field):
            return "invalid_\(field.replacingOccurrences(of: "-", with: "_"))"
        }
    }
}

/// A process-test-only transport fault. It is activated only when this class
/// is placed in the caller-provided ephemeral URLSessionConfiguration.
///
/// `block-before-send` proves that an intercepted but unacknowledged WAL entry
/// survives process termination. `lose-ack-after-200` forwards the original
/// signed request to BOE, records only a non-sensitive HTTP-200 marker, and
/// deliberately withholds the response from the Producer so a restart must
/// replay a server-accepted/client-unacknowledged batch.
private final class RecoveryFaultURLProtocol: URLProtocol,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    private static let forwardedProperty = "VolcengineTLSRecoveryForwarded"
    private var forwardingTask: URLSessionDataTask?
    private var session: URLSession?

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(
            forKey: forwardedProperty,
            in: request) == nil,
            request.url?.scheme?.lowercased() == "https",
            let rawMode = ProcessInfo.processInfo.environment[
                "TLS_SIMULATOR_NETWORK_FAULT"],
            let mode = NetworkFaultMode(rawValue: rawMode.lowercased()) else {
            return false
        }
        return mode != .direct
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let rawMode = ProcessInfo.processInfo.environment[
            "TLS_SIMULATOR_NETWORK_FAULT"],
            let mode = NetworkFaultMode(rawValue: rawMode.lowercased()),
            mode != .direct else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL))
            return
        }

        if mode == .blockBeforeSend {
            Self.writeNetworkMarker(
                event: "request_intercepted",
                serverAccepted: false,
                httpStatus: nil)
            return
        }

        let mutableRequest = (request as NSURLRequest).mutableCopy()
            as! NSMutableURLRequest
        URLProtocol.setProperty(
            true,
            forKey: Self.forwardedProperty,
            in: mutableRequest)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil)
        self.session = session
        forwardingTask = session.dataTask(
            with: mutableRequest as URLRequest
        ) { [weak self] data, response, error in
            guard let self else { return }
            if let http = response as? HTTPURLResponse,
               http.statusCode == 200,
               error == nil {
                Self.writeNetworkMarker(
                    event: "server_http_200_response_withheld",
                    serverAccepted: true,
                    httpStatus: http.statusCode)
                // Intentionally do not finish the URLProtocol request. The
                // host terminates this process only after observing the
                // durable marker, leaving the Core WAL unacknowledged.
                return
            }
            if let response {
                self.client?.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed)
            }
            if let data, !data.isEmpty {
                self.client?.urlProtocol(self, didLoad: data)
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
            session.finishTasksAndInvalidate()
        }
        forwardingTask?.resume()
    }

    override func stopLoading() {
        forwardingTask?.cancel()
        session?.invalidateAndCancel()
        forwardingTask = nil
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // This forwarding path exists only to create a controlled lost-ACK
        // window. Never follow a redirect with the already signed request.
        completionHandler(nil)
    }

    private static func writeNetworkMarker(
        event: String,
        serverAccepted: Bool,
        httpStatus: Int?
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard let runID = environment["TLS_SIMULATOR_RUN_ID"],
              let scenario = environment["TLS_SIMULATOR_SCENARIO"],
              let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask).first else {
            return
        }
        var object: [String: Any] = [
            "schemaVersion": 1,
            "marker": "network_fault_ready",
            "event": event,
            "runID": runID,
            "scenario": scenario,
            "serverAccepted": serverAccepted,
            "createdAtMilliseconds": Int64(Date().timeIntervalSince1970 * 1_000),
        ]
        if let httpStatus {
            object["httpStatus"] = httpStatus
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        let url = directory.appendingPathComponent(
            "simulator-recovery-network-marker.json",
            isDirectory: false)
        try? data.write(to: url, options: [.atomic])
    }
}

private final class ResultCollector: @unchecked Sendable {
    struct Snapshot {
        let observedResultCount: Int
        let successCount: Int
        let failureCount: Int
        let errorCodes: [String]
        let totalRawBytes: Int
        let totalCompressedBytes: Int
        let requestIDCount: Int
    }

    private let lock = NSLock()
    private var observedResultCount = 0
    private var successCount = 0
    private var failureCount = 0
    private var errorCodes = Set<String>()
    private var totalRawBytes = 0
    private var totalCompressedBytes = 0
    private var requestIDCount = 0

    func record(_ result: SendResult) {
        lock.lock()
        observedResultCount += 1
        switch result.status {
        case .success:
            successCount += 1
        case .failure:
            failureCount += 1
        }
        if let error = result.error {
            errorCodes.insert(error.errorCode)
        }
        totalRawBytes = Self.saturatingAdd(totalRawBytes, result.rawBytes)
        totalCompressedBytes = Self.saturatingAdd(
            totalCompressedBytes,
            result.compressedBytes)
        if let requestID = result.requestID, !requestID.isEmpty {
            requestIDCount += 1
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            observedResultCount: observedResultCount,
            successCount: successCount,
            failureCount: failureCount,
            errorCodes: errorCodes.sorted(),
            totalRawBytes: totalRawBytes,
            totalCompressedBytes: totalCompressedBytes,
            requestIDCount: requestIDCount)
        lock.unlock()
        return snapshot
    }

    func waitForAtLeast(_ expected: Int, timeout: TimeInterval) async -> Snapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = snapshot()
            if current.observedResultCount >= expected {
                return current
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return snapshot()
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

private struct VolumeAdmissionSnapshot: Sendable {
    let generatedCount: Int
    let accepted: Int
    let generatedFieldBytes: Int
    let acceptedFieldBytes: Int
    let errorCodes: [String]
}

private final class VolumeAdmissionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var generatedCount = 0
    private var accepted = 0
    private var generatedFieldBytes = 0
    private var acceptedFieldBytes = 0
    private var errorCodes = Set<String>()

    func recordGenerated(_ event: GeneratedEvent) {
        lock.lock()
        generatedCount += 1
        generatedFieldBytes = Self.saturatingAdd(
            generatedFieldBytes,
            event.rawFieldBytes)
        lock.unlock()
    }

    func recordAccepted(_ event: GeneratedEvent) {
        lock.lock()
        accepted += 1
        acceptedFieldBytes = Self.saturatingAdd(
            acceptedFieldBytes,
            event.rawFieldBytes)
        lock.unlock()
    }

    func recordError(_ errorCode: String) {
        lock.lock()
        errorCodes.insert(errorCode)
        lock.unlock()
    }

    func snapshot() -> VolumeAdmissionSnapshot {
        lock.lock()
        let snapshot = VolumeAdmissionSnapshot(
            generatedCount: generatedCount,
            accepted: accepted,
            generatedFieldBytes: generatedFieldBytes,
            acceptedFieldBytes: acceptedFieldBytes,
            errorCodes: errorCodes.sorted())
        lock.unlock()
        return snapshot
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

private struct SeedState: Codable {
    let schemaVersion: Int
    let marker: String
    let runID: String
    let scenario: String
    let networkFault: String
    let persistence: String
    let producerID: String
    let acceptedLogCount: Int
    let rawBytesPerLog: Int
    let createdAt: Date
}

private struct RunResult: Codable {
    let schemaVersion: Int
    let marker: String
    let runID: String
    let scenario: String
    let mode: String
    let persistence: String
    let producerID: String
    let acceptedLogCount: Int
    let expectedResultCount: Int
    let observedResultCount: Int
    let successCount: Int
    let failureCount: Int
    let outcome: String
    let errorCodes: [String]
    let finishedAt: Date
}

/// Stable, standalone result schema for the high-capacity volume run. It is
/// intentionally separate from the legacy recovery/soak result so external
/// BOE verification can consume the aggregate byte and lifecycle evidence
/// without depending on old fields.
private struct VolumeResult: Codable {
    let schemaVersion: Int
    let marker: String
    let profile: String
    let runID: String
    let persistence: String
    let acceptedLogCount: Int
    /// Exact UTF-8 bytes admitted through public LogEvent key/value fields.
    /// This intentionally excludes protobuf, timestamp, and LogGroup metadata
    /// overhead included by the Core's `observedRawBytes` metric.
    let admittedFieldBytes: Int
    let observedRawBytes: Int
    let observedResultCount: Int
    let successCount: Int
    let failureCount: Int
    let compressedBytes: Int
    let requestIDCount: Int
    let admissionMilliseconds: Int64
    let drainMilliseconds: Int64
    let closeOutcome: String
    let errorCodes: [String]
    let startedAt: Date
    let finishedAt: Date
    let targetLogsPerSecond: Double?
    let outcome: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case marker
        case profile
        case runID
        case persistence
        case acceptedLogCount
        case admittedFieldBytes
        case observedRawBytes
        case observedResultCount
        case successCount
        case failureCount
        case compressedBytes
        case requestIDCount
        case admissionMilliseconds
        case drainMilliseconds
        case closeOutcome
        case errorCodes
        case startedAt
        case finishedAt
        case targetLogsPerSecond
        case outcome
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(marker, forKey: .marker)
        try container.encode(profile, forKey: .profile)
        try container.encode(runID, forKey: .runID)
        try container.encode(persistence, forKey: .persistence)
        try container.encode(acceptedLogCount, forKey: .acceptedLogCount)
        try container.encode(admittedFieldBytes, forKey: .admittedFieldBytes)
        try container.encode(observedRawBytes, forKey: .observedRawBytes)
        try container.encode(observedResultCount, forKey: .observedResultCount)
        try container.encode(successCount, forKey: .successCount)
        try container.encode(failureCount, forKey: .failureCount)
        try container.encode(compressedBytes, forKey: .compressedBytes)
        try container.encode(requestIDCount, forKey: .requestIDCount)
        try container.encode(admissionMilliseconds, forKey: .admissionMilliseconds)
        try container.encode(drainMilliseconds, forKey: .drainMilliseconds)
        try container.encode(closeOutcome, forKey: .closeOutcome)
        try container.encode(errorCodes, forKey: .errorCodes)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
        // Explicitly encode null when no aggregate pacing was requested so
        // every VolumeResult has the same frozen key set.
        try container.encode(targetLogsPerSecond, forKey: .targetLogsPerSecond)
        try container.encode(outcome, forKey: .outcome)
    }
}

private final class SimulatorRecoveryRunner: @unchecked Sendable {
    private static let stateFileName = "simulator-recovery-state.json"
    private static let resultFileName = "simulator-recovery-result.json"
    private static let volumeResultFileName = "simulator-volume-result.json"
    private static let testAccessKeyID = "simulator-test-ak"
    private static let testAccessKeySecret = "simulator-test-sk"
    private static let rawBytesPerLog = 1_024
    private static let payloadBytes = 1_017
    private static let volumePayloadAlphabet = Array(
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_")
        .compactMap { $0.asciiValue }
    private static let volumeHashKeys: [String] = (0..<256).map {
        makeVolumeHashKey(index: $0)
    }

    private static func makeVolumeHashKey(index: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        switch index {
        case 0:
            // Lower boundary: 0x0000...0000.
            break
        case 1:
            // Signed-boundary byte 0x7f across the complete 128-bit width.
            bytes = [UInt8](repeating: 0x7f, count: 16)
        case 2:
            // Signed-boundary byte 0x80 across the complete 128-bit width.
            bytes = [UInt8](repeating: 0x80, count: 16)
        case 3:
            // Upper non-all-f boundary: 0xffff...fffe.
            bytes = [UInt8](repeating: 0xff, count: 16)
            bytes[15] = 0xfe
        default:
            // Keep all 16 bytes meaningful. The first byte makes every key
            // distinct while the remaining bytes exercise the full byte
            // range instead of concentrating entropy in the low 8 bits.
            bytes[0] = UInt8(truncatingIfNeeded: index)
            var state = UInt64(index) &+ 0x9E37_79B9_7F4A_7C15
            for position in 1..<bytes.count {
                state = state &* 6_364_136_223_846_793_005 &+
                    1_442_695_040_888_963_407
                bytes[position] = UInt8(truncatingIfNeeded: state >> 56)
            }
            if bytes.allSatisfy({ $0 == 0xff }) {
                bytes[15] = 0xfe
            }
        }
        let alphabet = Array("0123456789abcdef")
        return bytes.map { byte in
            String(alphabet[Int(byte >> 4)]) +
                String(alphabet[Int(byte & 0x0f)])
        }.joined()
    }

    private var producer: Producer?
    private let documentsURL: URL

    init() {
        documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask).first!
    }

    func start() {
        Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        do {
            let input = try HarnessInput()
            switch input.mode {
            case .seed:
                try await runSeed(input)
            case .recover:
                try await runRecover(input)
            case .soak:
                try await runSoak(input)
            case .volume:
                try await runVolume(input)
            }
        } catch let error as HarnessInputError {
            writeUnconfiguredResult(error.code)
            print("[simulator-recovery] configuration failed: \(error.code)")
        } catch let error as ProducerError {
            writeUnconfiguredResult(error.errorCode)
            print("[simulator-recovery] producer failed: \(error.errorCode)")
        } catch {
            writeUnconfiguredResult("internal")
            print("[simulator-recovery] internal failure")
        }
    }

    private func runSeed(_ input: HarnessInput) async throws {
        guard let seedCount = input.seedCount else {
            throw HarnessInputError.missingOrInvalid("seed-count")
        }

        let collector = ResultCollector()
        producer = try await openProducer(input, collector: collector)
        for sequence in 0..<seedCount {
            try producer!.add(
                makeOneKiBEvent(sequence: sequence, input: input),
                mode: .immediate)
        }

        let state = SeedState(
            schemaVersion: 1,
            marker: "seed_ready",
            runID: input.runID,
            scenario: input.scenario,
            networkFault: input.networkFaultMode.rawValue,
            persistence: input.persistence.rawValue,
            producerID: input.producerID,
            acceptedLogCount: seedCount,
            rawBytesPerLog: Self.rawBytesPerLog,
            createdAt: Date())
        try writeJSON(state, fileName: Self.stateFileName)
        print("[simulator-recovery] seed_ready accepted=\(seedCount)")
    }

    private func runRecover(_ input: HarnessInput) async throws {
        let state: SeedState
        do {
            state = try readJSON(SeedState.self, fileName: Self.stateFileName)
        } catch {
            let result = RunResult(
                schemaVersion: 1,
                marker: "result_ready",
                runID: input.runID,
                scenario: input.scenario,
                mode: input.mode.rawValue,
                persistence: input.persistence.rawValue,
                producerID: input.producerID,
                acceptedLogCount: 0,
                expectedResultCount: 0,
                observedResultCount: 0,
                successCount: 0,
                failureCount: 0,
                outcome: "error",
                errorCodes: ["state_missing"],
                finishedAt: Date())
            try? writeJSON(result, fileName: Self.resultFileName)
            print("[simulator-recovery] result_ready outcome=error error=state_missing")
            return
        }

        guard state.marker == "seed_ready",
              state.runID == input.runID,
              state.scenario == input.scenario,
              state.persistence == input.persistence.rawValue,
              state.producerID == input.producerID else {
            let result = RunResult(
                schemaVersion: 1,
                marker: "result_ready",
                runID: input.runID,
                scenario: input.scenario,
                mode: input.mode.rawValue,
                persistence: input.persistence.rawValue,
                producerID: input.producerID,
                acceptedLogCount: state.acceptedLogCount,
                expectedResultCount: state.acceptedLogCount,
                observedResultCount: 0,
                successCount: 0,
                failureCount: 0,
                outcome: "error",
                errorCodes: ["state_mismatch"],
                finishedAt: Date())
            try? writeJSON(result, fileName: Self.resultFileName)
            print("[simulator-recovery] result_ready outcome=error error=state_mismatch")
            return
        }

        let collector = ResultCollector()
        producer = try await openProducer(input, collector: collector)
        let snapshot = await collector.waitForAtLeast(
            state.acceptedLogCount,
            timeout: input.recoveryTimeout)
        let outcome: String
        if snapshot.observedResultCount == state.acceptedLogCount,
           snapshot.successCount == state.acceptedLogCount,
           snapshot.failureCount == 0 {
            outcome = "success"
        } else if snapshot.observedResultCount == 0 {
            outcome = "blocked"
        } else if snapshot.observedResultCount < state.acceptedLogCount {
            outcome = "incomplete"
        } else {
            outcome = "unexpected_results"
        }
        let result = RunResult(
            schemaVersion: 1,
            marker: "result_ready",
            runID: input.runID,
            scenario: input.scenario,
            mode: input.mode.rawValue,
            persistence: input.persistence.rawValue,
            producerID: input.producerID,
            acceptedLogCount: state.acceptedLogCount,
            expectedResultCount: state.acceptedLogCount,
            observedResultCount: snapshot.observedResultCount,
            successCount: snapshot.successCount,
            failureCount: snapshot.failureCount,
            outcome: outcome,
            errorCodes: snapshot.errorCodes,
            finishedAt: Date())
        try writeJSON(result, fileName: Self.resultFileName)
        print("[simulator-recovery] result_ready outcome=\(outcome) observed=\(snapshot.observedResultCount)")
    }

    private func runSoak(_ input: HarnessInput) async throws {
        guard let duration = input.soakDuration,
              let interval = input.soakInterval else {
            throw HarnessInputError.missingOrInvalid("soak-duration-or-interval")
        }

        let collector = ResultCollector()
        producer = try await openProducer(input, collector: collector)
        let started = SeedState(
            schemaVersion: 1,
            marker: "soak_started",
            runID: input.runID,
            scenario: input.scenario,
            networkFault: input.networkFaultMode.rawValue,
            persistence: input.persistence.rawValue,
            producerID: input.producerID,
            acceptedLogCount: 0,
            rawBytesPerLog: Self.rawBytesPerLog,
            createdAt: Date())
        try writeJSON(started, fileName: Self.stateFileName)

        let deadline = Date().addingTimeInterval(duration)
        var accepted = 0
        var admissionErrorCodes = Set<String>()
        while Date() < deadline {
            do {
                try producer!.add(
                    makeOneKiBEvent(sequence: accepted, input: input),
                    mode: .immediate)
                accepted += 1
            } catch let error as ProducerError {
                admissionErrorCodes.insert(error.errorCode)
            } catch {
                admissionErrorCodes.insert("internal")
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        // Admission completion is not a terminal send result. Give every
        // accepted log a bounded drain window before evaluating the soak so
        // a slow sender can never be reported as a false success.
        let snapshot = await collector.waitForAtLeast(
            accepted,
            timeout: input.recoveryTimeout)
        let allErrors = Set(snapshot.errorCodes).union(admissionErrorCodes).sorted()
        let outcome: String
        if !admissionErrorCodes.isEmpty {
            outcome = "admission_failed"
        } else if snapshot.observedResultCount == accepted,
                  snapshot.successCount == accepted,
                  snapshot.failureCount == 0 {
            outcome = "completed"
        } else if snapshot.observedResultCount == 0 {
            outcome = "blocked"
        } else if snapshot.observedResultCount < accepted {
            outcome = "incomplete"
        } else if snapshot.failureCount > 0 {
            outcome = "service_failed"
        } else {
            outcome = "unexpected_results"
        }
        let result = RunResult(
            schemaVersion: 1,
            marker: "result_ready",
            runID: input.runID,
            scenario: input.scenario,
            mode: input.mode.rawValue,
            persistence: input.persistence.rawValue,
            producerID: input.producerID,
            acceptedLogCount: accepted,
            expectedResultCount: accepted,
            observedResultCount: snapshot.observedResultCount,
            successCount: snapshot.successCount,
            failureCount: snapshot.failureCount,
            outcome: outcome,
            errorCodes: allErrors,
            finishedAt: Date())
        try writeJSON(result, fileName: Self.resultFileName)
        print("[simulator-recovery] result_ready outcome=\(outcome) accepted=\(accepted)")
    }

    private func runVolume(_ input: HarnessInput) async throws {
        guard let profile = input.volumeProfile,
              let seedCount = input.seedCount else {
            throw HarnessInputError.missingOrInvalid("volume-profile-or-seed-count")
        }

        let startedAt = Date()
        let admissionStart = DispatchTime.now().uptimeNanoseconds

        guard profile.accepts(input.persistence) else {
            let finishedAt = Date()
            let result = VolumeResult(
                schemaVersion: 1,
                marker: "volume_result_ready",
                profile: profile.rawValue,
                runID: input.runID,
                persistence: input.persistence.rawValue,
                acceptedLogCount: 0,
                admittedFieldBytes: 0,
                observedRawBytes: 0,
                observedResultCount: 0,
                successCount: 0,
                failureCount: 0,
                compressedBytes: 0,
                requestIDCount: 0,
                admissionMilliseconds: 0,
                drainMilliseconds: 0,
                closeOutcome: "not_attempted",
                errorCodes: ["invalid_volume_persistence"],
                startedAt: startedAt,
                finishedAt: finishedAt,
                targetLogsPerSecond: input.targetLogsPerSecond,
                outcome: "configuration_error")
            try writeJSON(result, fileName: Self.volumeResultFileName)
            print("[simulator-volume] result_ready outcome=configuration_error")
            return
        }

        // A retain-and-recover run must have real credentials available for
        // the second half. The invalid first secret is generated below and is
        // never persisted or printed.
        if profile == .authRetainBulk,
           (input.accessKeyID?.isEmpty != false ||
            input.accessKeySecret?.isEmpty != false) {
            let finishedAt = Date()
            let result = VolumeResult(
                schemaVersion: 1,
                marker: "volume_result_ready",
                profile: profile.rawValue,
                runID: input.runID,
                persistence: input.persistence.rawValue,
                acceptedLogCount: 0,
                admittedFieldBytes: 0,
                observedRawBytes: 0,
                observedResultCount: 0,
                successCount: 0,
                failureCount: 0,
                compressedBytes: 0,
                requestIDCount: 0,
                admissionMilliseconds: 0,
                drainMilliseconds: 0,
                closeOutcome: "not_attempted",
                errorCodes: ["credentials_required_for_auth_retain"],
                startedAt: startedAt,
                finishedAt: finishedAt,
                targetLogsPerSecond: input.targetLogsPerSecond,
                outcome: "configuration_error")
            try writeJSON(result, fileName: Self.volumeResultFileName)
            print("[simulator-volume] result_ready outcome=configuration_error")
            return
        }

        let destination = makeDestination(input)
        let validCredentials = makeVolumeCredentials(input)
        let initialCredentials: Credentials
        if profile == .authRetainBulk {
            if let initialAccessKeyID = input.initialAccessKeyID,
               let initialAccessKeySecret = input.initialAccessKeySecret {
                initialCredentials = Credentials(
                    accessKeyID: initialAccessKeyID,
                    accessKeySecret: initialAccessKeySecret,
                    securityToken: input.initialSecurityToken)
            } else {
                initialCredentials = Credentials(
                    accessKeyID: validCredentials.accessKeyID,
                    // Deliberately invalid and process-local. It is used only
                    // to enter the Core's unauthorized/retain state.
                    accessKeySecret: "invalid-volume-sk-\(UUID().uuidString)",
                    securityToken: validCredentials.securityToken)
            }
        } else {
            initialCredentials = validCredentials
        }

        let collector = ResultCollector()
        let callbackQueue = DispatchQueue(
            label: "com.volcengine.tls.simulator-volume.callback",
            qos: .utility)
        do {
            producer = try await openVolumeProducer(
                input,
                profile: profile,
                destination: destination,
                credentials: initialCredentials,
                collector: collector,
                callbackQueue: callbackQueue)
        } catch let error as ProducerError {
            let finishedAt = Date()
            let result = VolumeResult(
                schemaVersion: 1,
                marker: "volume_result_ready",
                profile: profile.rawValue,
                runID: input.runID,
                persistence: input.persistence.rawValue,
                acceptedLogCount: 0,
                admittedFieldBytes: 0,
                observedRawBytes: 0,
                observedResultCount: 0,
                successCount: 0,
                failureCount: 0,
                compressedBytes: 0,
                requestIDCount: 0,
                admissionMilliseconds: 0,
                drainMilliseconds: 0,
                closeOutcome: "not_attempted",
                errorCodes: [error.errorCode],
                startedAt: startedAt,
                finishedAt: finishedAt,
                targetLogsPerSecond: input.targetLogsPerSecond,
                outcome: "open_failed")
            try writeJSON(result, fileName: Self.volumeResultFileName)
            print("[simulator-volume] result_ready outcome=open_failed")
            return
        } catch {
            let finishedAt = Date()
            let result = VolumeResult(
                schemaVersion: 1,
                marker: "volume_result_ready",
                profile: profile.rawValue,
                runID: input.runID,
                persistence: input.persistence.rawValue,
                acceptedLogCount: 0,
                admittedFieldBytes: 0,
                observedRawBytes: 0,
                observedResultCount: 0,
                successCount: 0,
                failureCount: 0,
                compressedBytes: 0,
                requestIDCount: 0,
                admissionMilliseconds: 0,
                drainMilliseconds: 0,
                closeOutcome: "not_attempted",
                errorCodes: ["internal"],
                startedAt: startedAt,
                finishedAt: finishedAt,
                targetLogsPerSecond: input.targetLogsPerSecond,
                outcome: "open_failed")
            try writeJSON(result, fileName: Self.volumeResultFileName)
            print("[simulator-volume] result_ready outcome=open_failed")
            return
        }

        guard let producer else {
            throw ProducerError.internal("volume producer was not opened")
        }

        // Keep a deterministic non-zero sub-millisecond component so the
        // online Consume verifier proves both protobuf Time milliseconds and
        // optional TimeNs remainder survive the complete iOS -> C Core path.
        let nowMilliseconds = Date().timeIntervalSince1970 * 1_000
        let eventTime = Date(
            timeIntervalSince1970:
                (nowMilliseconds.rounded(.down) + 0.456_789) / 1_000)
        let rateLimiter = VolumeRateLimiter(
            targetLogsPerSecond: input.targetLogsPerSecond)
        let admission = VolumeAdmissionCollector()
        var operationErrorCodes = Set<String>()

        if profile == .hotUpdate {
            let split = seedCount / 2
            await Self.admitVolumeRange(
                0..<split,
                seedCount: seedCount,
                input: input,
                profile: profile,
                eventTime: eventTime,
                producer: producer,
                rateLimiter: rateLimiter,
                admission: admission)
            do {
                try producer.updateCredentials(validCredentials)
            } catch let error as ProducerError {
                operationErrorCodes.insert("updateCredentials_\(error.errorCode)")
            } catch {
                operationErrorCodes.insert("updateCredentials_internal")
            }
            do {
                // The update intentionally names the same target. This
                // exercises atomic replacement without introducing a second
                // topic or changing the BOE verification scope.
                try producer.updateDestination(destination)
            } catch let error as ProducerError {
                operationErrorCodes.insert("updateDestination_\(error.errorCode)")
            } catch {
                operationErrorCodes.insert("updateDestination_internal")
            }
            await Self.admitVolumeRange(
                split..<seedCount,
                seedCount: seedCount,
                input: input,
                profile: profile,
                eventTime: eventTime,
                producer: producer,
                rateLimiter: rateLimiter,
                admission: admission)
        } else if profile == .hashRouting {
            // Four disjoint ranges share one rate limiter. There is no per-
            // worker rate multiplier and no overlap in sequence numbers.
            await withTaskGroup(of: Void.self) { group in
                for worker in 0..<4 {
                    let lower = seedCount * worker / 4
                    let upper = seedCount * (worker + 1) / 4
                    group.addTask {
                        await Self.admitVolumeRange(
                            lower..<upper,
                            seedCount: seedCount,
                            input: input,
                            profile: profile,
                            eventTime: eventTime,
                            producer: producer,
                            rateLimiter: rateLimiter,
                            admission: admission)
                    }
                }
                await group.waitForAll()
            }
        } else {
            await Self.admitVolumeRange(
                0..<seedCount,
                seedCount: seedCount,
                input: input,
                profile: profile,
                eventTime: eventTime,
                producer: producer,
                rateLimiter: rateLimiter,
                admission: admission)
        }

        let admissionEnd = DispatchTime.now().uptimeNanoseconds
        let admissionSnapshot = admission.snapshot()
        let admissionMilliseconds = Self.elapsedMilliseconds(
            from: admissionStart,
            to: admissionEnd)
        let drainStart = admissionEnd

        if profile == .authRetainBulk {
            let beforeUpdate = collector.snapshot()
            // This delay is only the explicit unauthorized-retain observation
            // window. Completion is still decided by measured terminal bytes.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let afterObservation = collector.snapshot()
            if afterObservation.observedResultCount !=
                beforeUpdate.observedResultCount {
                operationErrorCodes.insert("auth_retain_terminal_before_update")
            }
            do {
                try producer.updateCredentials(validCredentials)
            } catch let error as ProducerError {
                operationErrorCodes.insert("updateCredentials_\(error.errorCode)")
            } catch {
                operationErrorCodes.insert("updateCredentials_internal")
            }
            do {
                try producer.updateDestination(destination)
            } catch let error as ProducerError {
                operationErrorCodes.insert("updateDestination_\(error.errorCode)")
            } catch {
                operationErrorCodes.insert("updateDestination_internal")
            }
        }

        var closeOutcome = "not_attempted"
        do {
            try await producer.close(timeout: input.recoveryTimeout)
            closeOutcome = "success"
        } catch let error as ProducerError {
            closeOutcome = "failure"
            operationErrorCodes.insert("close_\(error.errorCode)")
        } catch {
            closeOutcome = "failure"
            operationErrorCodes.insert("close_internal")
        }

        // `close` joins Core workers, while public results are delivered on
        // the caller-provided serial queue. This barrier deterministically
        // drains every callback enqueued before close returned.
        callbackQueue.sync {}
        let snapshot = collector.snapshot()
        let drainEnd = DispatchTime.now().uptimeNanoseconds

        var errorCodes = Set(admissionSnapshot.errorCodes)
        errorCodes.formUnion(operationErrorCodes)
        errorCodes.formUnion(snapshot.errorCodes)

        let allTerminalResultsSucceeded =
            snapshot.observedResultCount > 0 &&
            snapshot.successCount == snapshot.observedResultCount &&
            snapshot.failureCount == 0
        // Core raw bytes are the uncompressed protobuf LogGroup size. They
        // include per-log wire fields, timestamps, and group metadata, while
        // acceptedFieldBytes is only the exact public key/value UTF-8 total.
        let terminalByteCoverage =
            snapshot.totalRawBytes >= admissionSnapshot.acceptedFieldBytes
        let success = admissionSnapshot.generatedCount == seedCount &&
            admissionSnapshot.accepted == seedCount &&
            admissionSnapshot.errorCodes.isEmpty &&
            operationErrorCodes.isEmpty &&
            admissionSnapshot.generatedFieldBytes ==
                admissionSnapshot.acceptedFieldBytes &&
            terminalByteCoverage &&
            allTerminalResultsSucceeded &&
            closeOutcome == "success"

        let outcome: String
        if success {
            outcome = "success"
        } else if admissionSnapshot.generatedCount != seedCount ||
                    admissionSnapshot.accepted != seedCount ||
                    !admissionSnapshot.errorCodes.isEmpty {
            outcome = "admission_failed"
        } else if closeOutcome != "success" {
            outcome = "close_failed"
        } else if snapshot.failureCount > 0 {
            outcome = "terminal_failed"
        } else if !allTerminalResultsSucceeded || !terminalByteCoverage {
            outcome = "terminal_incomplete"
        } else if !operationErrorCodes.isEmpty {
            outcome = "operation_failed"
        } else {
            outcome = "failed"
        }

        let finishedAt = Date()
        let result = VolumeResult(
            schemaVersion: 1,
            marker: "volume_result_ready",
            profile: profile.rawValue,
            runID: input.runID,
            persistence: input.persistence.rawValue,
            acceptedLogCount: admissionSnapshot.accepted,
            admittedFieldBytes: admissionSnapshot.acceptedFieldBytes,
            observedRawBytes: snapshot.totalRawBytes,
            observedResultCount: snapshot.observedResultCount,
            successCount: snapshot.successCount,
            failureCount: snapshot.failureCount,
            compressedBytes: snapshot.totalCompressedBytes,
            requestIDCount: snapshot.requestIDCount,
            admissionMilliseconds: admissionMilliseconds,
            drainMilliseconds: Self.elapsedMilliseconds(
                from: drainStart,
                to: drainEnd),
            closeOutcome: closeOutcome,
            errorCodes: errorCodes.sorted(),
            startedAt: startedAt,
            finishedAt: finishedAt,
            targetLogsPerSecond: input.targetLogsPerSecond,
            outcome: outcome)
        try writeJSON(result, fileName: Self.volumeResultFileName)
        print(
            "[simulator-volume] result_ready profile=\(profile.rawValue) " +
                "outcome=\(outcome) accepted=\(admissionSnapshot.accepted) " +
                "callbacks=\(snapshot.observedResultCount)")
    }

    private static func admitVolumeRange(
        _ range: Range<Int>,
        seedCount: Int,
        input: HarnessInput,
        profile: VolumeProfile,
        eventTime: Date,
        producer: Producer,
        rateLimiter: VolumeRateLimiter,
        admission: VolumeAdmissionCollector
    ) async {
        for sequence in range {
            await rateLimiter.waitForSlot()
            let generated = makeVolumeEvent(
                sequence: sequence,
                seedCount: seedCount,
                input: input,
                profile: profile,
                eventTime: eventTime)
            admission.recordGenerated(generated)
            do {
                try producer.add(
                    generated.logEvent,
                    mode: volumeAddMode(
                        sequence: sequence,
                        seedCount: seedCount,
                        profile: profile))
                admission.recordAccepted(generated)
            } catch let error as ProducerError {
                admission.recordError(error.errorCode)
            } catch {
                admission.recordError("internal")
            }
        }
    }

    private func openVolumeProducer(
        _ input: HarnessInput,
        profile: VolumeProfile,
        destination: Destination,
        credentials: Credentials,
        collector: ResultCollector,
        callbackQueue: DispatchQueue
    ) async throws -> Producer {
        let profileConfiguration = profile.configuration
        let configuration = try ProducerConfiguration(
            batch: profileConfiguration.batch,
            buffer: profileConfiguration.buffer,
            sendConcurrency: profileConfiguration.sendConcurrency,
            compression: profileConfiguration.compression,
            persistence: input.persistence.producerPersistence,
            connectTimeout: 5,
            requestTimeout: 15,
            metadata: profileConfiguration.metadata,
            maxLogAge: 7 * 24 * 60 * 60,
            expiredLogPolicy: .rewriteTimestamp,
            unauthorizedPolicy: input.unauthorizedPolicy,
            callbackQueue: callbackQueue,
            urlSessionConfiguration: .ephemeral,
            automaticLifecycleHandling: false,
            producerID: input.producerID,
            destination: destination)
        return try await Producer.open(
            configuration: configuration,
            credentials: credentials,
            onSendResult: { result in
                collector.record(result)
            })
    }

    private static func makeVolumeEvent(
        sequence: Int,
        seedCount: Int,
        input: HarnessInput,
        profile: VolumeProfile,
        eventTime: Date
    ) -> GeneratedEvent {
        let profileConfiguration = profile.configuration
        let payload = deterministicPayload(
            sequence: sequence,
            length: profileConfiguration.payloadBytes)
        let timestampParts = volumeTimestampParts(eventTime)
        var contents: [String: LogValue] = [
            "run_id": .string(input.runID),
            "scenario": .string(input.scenario),
            "persistence": .string(input.persistence.rawValue),
            "profile": .string(profile.rawValue),
            "seq": .signedInt(Int64(sequence)),
            "event_time_ms": .signedInt(timestampParts.milliseconds),
            "event_time_ns_remainder": .unsignedInt(
                UInt64(timestampParts.nanosecondsRemainder)),
            "payload_size": .signedInt(Int64(payload.utf8.count)),
            "payload": .string(payload),
        ]

        switch profile {
        case .hashRouting:
            // The fixed 4096-event matrix is exactly 256 keys x 16 events.
            // Keep this mapping one-to-one with the sequence so every key has
            // the same frequency and the hash-routing run does not dilute the
            // matrix with nil hash keys.
            let slot = sequence % volumeHashKeys.count
            contents["hash_slot"] = .signedInt(Int64(slot))
        case .mixedImmediate:
            contents["admission_mode"] = .string(
                volumeAddMode(
                    sequence: sequence,
                    seedCount: seedCount,
                    profile: profile) == .immediate ? "immediate" : "normal")
        case .complexDataDefault, .complexDataCustom:
            contents["unicode"] = .string("业务-日志-🙂-\(sequence)")
            contents["complex"] = .dictionary([
                "array": .array([
                    .string("元素🙂"),
                    .signedInt(Int64(sequence)),
                    .bool(sequence % 2 == 0),
                    .null,
                ]),
                "bytes": .utf8Data(Data("字节-🙂-\(sequence)".utf8)),
                "count": .unsignedInt(UInt64(sequence)),
                "nested": .dictionary([
                    "a": .double(3.14159),
                    "区域": .string("华东"),
                ]),
            ])
        case .hotUpdate:
            contents["update_phase"] = .string(
                sequence < seedCount / 2 ? "before" : "after")
        case .authRetainBulk:
            contents["auth_phase"] = .string("retain-bulk")
        case .defaultLZ4, .noCompressionCount, .bufferedHighConcurrency,
             .syncMaxCount:
            break
        }

        let hashKey: String?
        if profile == .hashRouting {
            hashKey = volumeHashKeys[sequence % volumeHashKeys.count]
        } else {
            hashKey = nil
        }
        let logEvent = LogEvent(
            timestamp: eventTime,
            hashKey: hashKey,
            contents: contents)
        return GeneratedEvent(
            logEvent: logEvent,
            rawFieldBytes: rawFieldBytes(contents))
    }

    private static func volumeTimestampParts(
        _ timestamp: Date
    ) -> (milliseconds: Int64, nanosecondsRemainder: UInt32) {
        let rawMilliseconds = timestamp.timeIntervalSince1970 * 1_000
        var milliseconds = Int64(rawMilliseconds)
        var remainder = Int64(
            ((rawMilliseconds - Double(milliseconds)) * 1_000_000)
                .rounded(.toNearestOrAwayFromZero))
        if remainder >= 1_000_000 {
            milliseconds += 1
            remainder = 0
        }
        return (milliseconds, UInt32(max(0, remainder)))
    }

    private static func volumeAddMode(
        sequence: Int,
        seedCount: Int,
        profile: VolumeProfile
    ) -> AddMode {
        switch profile {
        case .mixedImmediate:
            return sequence % 2 == 0 ? .immediate : .normal
        case .authRetainBulk:
            // Seal exactly once after the complete invalid-credential batch
            // has been admitted so retain behavior is observed as a batch.
            return sequence + 1 == seedCount ? .immediate : .normal
        case .defaultLZ4, .noCompressionCount, .bufferedHighConcurrency,
             .syncMaxCount, .hashRouting, .complexDataDefault,
             .complexDataCustom, .hotUpdate:
            return .normal
        }
    }

    private static func rawFieldBytes(_ contents: [String: LogValue]) -> Int {
        contents.reduce(0) { total, entry in
            let fieldBytes = entry.key.utf8.count +
                volumeEncodedString(entry.value).utf8.count
            return saturatingAdd(total, fieldBytes)
        }
    }

    /// Mirrors the public `LogValue` encoding rules for the finite set of
    /// values generated above. Top-level strings are unquoted; strings nested
    /// in arrays/dictionaries use compact JSON quoting.
    private static func volumeEncodedString(
        _ value: LogValue,
        quoteStrings: Bool = false
    ) -> String {
        switch value {
        case .string(let string):
            return quoteStrings ? volumeJSONString(string) : string
        case .signedInt(let number):
            return String(number)
        case .unsignedInt(let number):
            return String(number)
        case .double(let number):
            return String(number)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let values):
            return "[" + values.map {
                volumeEncodedString($0, quoteStrings: true)
            }.joined(separator: ",") + "]"
        case .dictionary(let dictionary):
            let fields = dictionary.keys.sorted().map { key in
                volumeJSONString(key) + ":" +
                    volumeEncodedString(dictionary[key]!, quoteStrings: true)
            }
            return "{" + fields.joined(separator: ",") + "}"
        case .utf8Data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private static func volumeJSONString(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                output.append("\\\"")
            case "\\":
                output.append("\\\\")
            case "\u{8}":
                output.append("\\b")
            case "\u{c}":
                output.append("\\f")
            case "\n":
                output.append("\\n")
            case "\r":
                output.append("\\r")
            case "\t":
                output.append("\\t")
            default:
                if scalar.value < 0x20 {
                    output.append(String(format: "\\u%04x", scalar.value))
                } else {
                    output.append(contentsOf: String(scalar))
                }
            }
        }
        output.append("\"")
        return output
    }

    private static func deterministicPayload(sequence: Int, length: Int) -> String {
        var state = UInt64(sequence) &+ 0x9E37_79B9_7F4A_7C15
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        while bytes.count < length {
            state = state &* 6_364_136_223_846_793_005 &+
                1_442_695_040_888_963_407
            bytes.append(volumePayloadAlphabet[
                Int(state % UInt64(volumePayloadAlphabet.count))])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int64 {
        let nanoseconds = end >= start ? end - start : 0
        let milliseconds = nanoseconds / 1_000_000
        return milliseconds >= UInt64(Int64.max) ? Int64.max : Int64(milliseconds)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private func makeDestination(_ input: HarnessInput) -> Destination {
        Destination(
            endpoint: input.endpoint,
            region: input.region,
            projectID: input.projectID,
            topicID: input.topicID)
    }

    private func makeVolumeCredentials(_ input: HarnessInput) -> Credentials {
        Credentials(
            accessKeyID: input.accessKeyID ?? Self.testAccessKeyID,
            accessKeySecret: input.accessKeySecret ?? Self.testAccessKeySecret,
            securityToken: input.securityToken)
    }

    private func openProducer(
        _ input: HarnessInput,
        collector: ResultCollector
    ) async throws -> Producer {
        let destination = makeDestination(input)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        if input.networkFaultMode != .direct {
            sessionConfiguration.protocolClasses = [RecoveryFaultURLProtocol.self]
        }
        let configuration = try ProducerConfiguration(
            batch: BatchConfiguration(
                maxLogCount: 1,
                maxRawBytes: 19 * 512 * 1024,
                linger: 0),
            buffer: BufferConfiguration(
                maxBytes: 64 * 1024 * 1024,
                fullPolicy: .reject,
                blockTimeout: 1),
            sendConcurrency: 1,
            compression: .lz4,
            persistence: input.persistence.producerPersistence,
            connectTimeout: 5,
            requestTimeout: input.networkFaultMode == .direct ? 15 : 120,
            metadata: ProducerMetadata(source: "simulator-recovery"),
            maxLogAge: 7 * 24 * 60 * 60,
            expiredLogPolicy: .rewriteTimestamp,
            unauthorizedPolicy: .retain,
            callbackQueue: DispatchQueue(
                label: "com.volcengine.tls.simulator-recovery.callback",
                qos: .utility),
            urlSessionConfiguration: sessionConfiguration,
            automaticLifecycleHandling: false,
            producerID: input.producerID,
            destination: destination)
        let credentials = Credentials(
            accessKeyID: input.accessKeyID ?? Self.testAccessKeyID,
            accessKeySecret: input.accessKeySecret ?? Self.testAccessKeySecret,
            securityToken: input.securityToken)
        return try await Producer.open(
            configuration: configuration,
            credentials: credentials,
            onSendResult: { result in
                collector.record(result)
            })
    }

    private func makeOneKiBEvent(sequence: Int, input: HarnessInput) -> LogEvent {
        LogEvent(contents: [
            "run_id": .string(input.runID),
            "scenario": .string(input.scenario),
            "persistence": .string(input.persistence.rawValue),
            "seq": .signedInt(Int64(sequence)),
            "payload": .string(String(repeating: "x", count: Self.payloadBytes))
        ])
    }

    private func writeUnconfiguredResult(_ errorCode: String) {
        let result = RunResult(
            schemaVersion: 1,
            marker: "result_ready",
            runID: "unknown",
            scenario: "unknown",
            mode: "unknown",
            persistence: "unknown",
            producerID: "unknown",
            acceptedLogCount: 0,
            expectedResultCount: 0,
            observedResultCount: 0,
            successCount: 0,
            failureCount: 0,
            outcome: "error",
            errorCodes: [errorCode],
            finishedAt: Date())
        try? writeJSON(result, fileName: Self.resultFileName)

        if Self.commandLineOrEnvironment(
            argument: "mode",
            environment: "TLS_SIMULATOR_MODE")?.lowercased() ==
            HarnessMode.volume.rawValue {
            writeUnconfiguredVolumeResult(errorCode)
        }
    }

    private func writeUnconfiguredVolumeResult(_ errorCode: String) {
        let profile = VolumeProfile.parse(
            Self.commandLineOrEnvironment(
                argument: "volume-profile",
                environment: "TLS_SIMULATOR_VOLUME_PROFILE") ?? "")?.rawValue ?? "unknown"
        let persistence = PersistenceMode(
            rawValue: (Self.commandLineOrEnvironment(
                argument: "persistence",
                environment: "TLS_SIMULATOR_PERSISTENCE") ?? "").lowercased()
        )?.rawValue ?? "unknown"
        let runID: String
        if let candidate = Self.commandLineOrEnvironment(
            argument: "run-id",
            environment: "TLS_SIMULATOR_RUN_ID"),
           !candidate.contains("\0"),
           candidate.utf8.count <= 128 {
            runID = candidate
        } else {
            runID = "unknown"
        }
        let targetRate = Self.commandLineOrEnvironment(
            argument: "target-logs-per-second",
            environment: "TLS_SIMULATOR_TARGET_LOGS_PER_SECOND")
            .flatMap(Double.init)
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let now = Date()
        let result = VolumeResult(
            schemaVersion: 1,
            marker: "volume_result_ready",
            profile: profile,
            runID: runID,
            persistence: persistence,
            acceptedLogCount: 0,
            admittedFieldBytes: 0,
            observedRawBytes: 0,
            observedResultCount: 0,
            successCount: 0,
            failureCount: 0,
            compressedBytes: 0,
            requestIDCount: 0,
            admissionMilliseconds: 0,
            drainMilliseconds: 0,
            closeOutcome: "not_attempted",
            errorCodes: [errorCode],
            startedAt: now,
            finishedAt: now,
            targetLogsPerSecond: targetRate,
            outcome: "configuration_error")
        try? writeJSON(result, fileName: Self.volumeResultFileName)
    }

    private static func commandLineOrEnvironment(
        argument: String,
        environment: String
    ) -> String? {
        let prefix = "--\(argument)="
        let arguments = CommandLine.arguments
        if let inline = arguments.dropFirst().first(where: { $0.hasPrefix(prefix) }) {
            return String(inline.dropFirst(prefix.count))
        }
        if let index = arguments.dropFirst().firstIndex(of: "--\(argument)"),
           arguments.index(after: index) < arguments.endIndex {
            return arguments[arguments.index(after: index)]
        }
        return ProcessInfo.processInfo.environment[environment]
    }

    private func writeJSON<Value: Encodable>(_ value: Value, fileName: String) throws {
        let data = try JSONEncoder().encode(value)
        let url = documentsURL.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: url, options: [.atomic])
    }

    private func readJSON<Value: Decodable>(_ type: Value.Type, fileName: String) throws -> Value {
        let url = documentsURL.appendingPathComponent(fileName, isDirectory: false)
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }
}
