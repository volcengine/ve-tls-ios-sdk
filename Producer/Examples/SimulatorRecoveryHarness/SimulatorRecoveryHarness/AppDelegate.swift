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

private enum HarnessMode: String {
    case seed
    case recover
    case soak
}

private enum PersistenceMode: String {
    case buffered
    case sync
}

private struct HarnessInput {
    let mode: HarnessMode
    let endpoint: String
    let region: String
    let projectID: String
    let topicID: String
    let persistence: PersistenceMode
    let producerID: String
    let runID: String
    let seedCount: Int?
    let recoveryTimeout: TimeInterval
    let soakDuration: TimeInterval?
    let soakInterval: TimeInterval?

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
        if mode == .seed && seedCount == nil {
            throw HarnessInputError.missingOrInvalid("seed-count")
        }

        let recoveryTimeout = try HarnessInput.positiveDouble(
            argument: "recovery-timeout",
            environment: "TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS",
            defaultValue: 120)

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

        self.mode = mode
        self.endpoint = endpoint
        self.region = region
        self.projectID = projectID
        self.topicID = topicID
        self.persistence = persistence
        self.producerID = producerID
        self.runID = runID
        self.seedCount = seedCount
        self.recoveryTimeout = recoveryTimeout
        self.soakDuration = soakDuration
        self.soakInterval = soakInterval
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

private final class ResultCollector: @unchecked Sendable {
    struct Snapshot {
        let observedResultCount: Int
        let successCount: Int
        let failureCount: Int
        let errorCodes: [String]
    }

    private let lock = NSLock()
    private var observedResultCount = 0
    private var successCount = 0
    private var failureCount = 0
    private var errorCodes = Set<String>()

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
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            observedResultCount: observedResultCount,
            successCount: successCount,
            failureCount: failureCount,
            errorCodes: errorCodes.sorted())
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
}

private struct SeedState: Codable {
    let schemaVersion: Int
    let marker: String
    let runID: String
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

private final class SimulatorRecoveryRunner: @unchecked Sendable {
    private static let stateFileName = "simulator-recovery-state.json"
    private static let resultFileName = "simulator-recovery-result.json"
    private static let testAccessKeyID = "simulator-test-ak"
    private static let testAccessKeySecret = "simulator-test-sk"
    private static let rawBytesPerLog = 1_024
    private static let payloadBytes = 1_017

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
        let event = makeOneKiBEvent()
        for _ in 0..<seedCount {
            try producer!.add(event, mode: .immediate)
        }

        let state = SeedState(
            schemaVersion: 1,
            marker: "seed_ready",
            runID: input.runID,
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
              state.persistence == input.persistence.rawValue,
              state.producerID == input.producerID else {
            let result = RunResult(
                schemaVersion: 1,
                marker: "result_ready",
                runID: input.runID,
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
            persistence: input.persistence.rawValue,
            producerID: input.producerID,
            acceptedLogCount: 0,
            rawBytesPerLog: Self.rawBytesPerLog,
            createdAt: Date())
        try writeJSON(started, fileName: Self.stateFileName)

        let deadline = Date().addingTimeInterval(duration)
        let event = makeOneKiBEvent()
        var accepted = 0
        var admissionErrorCodes = Set<String>()
        while Date() < deadline {
            do {
                try producer!.add(event, mode: .immediate)
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

    private func openProducer(
        _ input: HarnessInput,
        collector: ResultCollector
    ) async throws -> Producer {
        let destination = Destination(
            endpoint: input.endpoint,
            region: input.region,
            projectID: input.projectID,
            topicID: input.topicID)
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
            persistence: input.persistence == .buffered ? .buffered : .sync,
            connectTimeout: 5,
            requestTimeout: 10,
            metadata: ProducerMetadata(source: "simulator-recovery"),
            maxLogAge: 7 * 24 * 60 * 60,
            expiredLogPolicy: .rewriteTimestamp,
            unauthorizedPolicy: .retain,
            callbackQueue: DispatchQueue(
                label: "com.volcengine.tls.simulator-recovery.callback",
                qos: .utility),
            urlSessionConfiguration: .ephemeral,
            automaticLifecycleHandling: false,
            producerID: input.producerID,
            destination: destination)
        let credentials = Credentials(
            accessKeyID: Self.testAccessKeyID,
            accessKeySecret: Self.testAccessKeySecret)
        return try await Producer.open(
            configuration: configuration,
            credentials: credentials,
            onSendResult: { result in
                collector.record(result)
            })
    }

    private func makeOneKiBEvent() -> LogEvent {
        LogEvent(contents: [
            "payload": .string(String(repeating: "x", count: Self.payloadBytes))
        ])
    }

    private func writeUnconfiguredResult(_ errorCode: String) {
        let result = RunResult(
            schemaVersion: 1,
            marker: "result_ready",
            runID: "unknown",
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
