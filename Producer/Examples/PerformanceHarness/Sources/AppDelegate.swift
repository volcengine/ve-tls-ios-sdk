import Foundation
import UIKit
import VolcengineTLSProducer

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private var runner: PerformanceRunner?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let runner = PerformanceRunner()
        self.runner = runner
        runner.start()
        return true
    }
}

private enum SDKKind: String {
    case tls
    case sls
}

private enum StorageMode: String {
    case memory
    case persistent
}

private struct PerformanceInput {
    let sdk: SDKKind
    let mode: StorageMode
    let endpoint: String
    let rate: Int
    let warmupSeconds: Double
    let measureSeconds: Double
    let settleTimeoutSeconds: Double
    let runID: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else {
                throw InputError.invalid(name)
            }
            return value
        }
        guard let sdk = SDKKind(rawValue: try required("TLS_PERF_SDK")) else {
            throw InputError.invalid("TLS_PERF_SDK")
        }
        guard let mode = StorageMode(rawValue: try required("TLS_PERF_MODE")) else {
            throw InputError.invalid("TLS_PERF_MODE")
        }
        let endpoint = try required("TLS_PERF_ENDPOINT")
        guard let rate = Int(try required("TLS_PERF_RATE")),
              (1...10_000).contains(rate) else {
            throw InputError.invalid("TLS_PERF_RATE")
        }
        let warmupSeconds = try Self.positiveDouble(
            environment["TLS_PERF_WARMUP_SECONDS"] ?? "10",
            name: "TLS_PERF_WARMUP_SECONDS")
        let measureSeconds = try Self.positiveDouble(
            environment["TLS_PERF_MEASURE_SECONDS"] ?? "30",
            name: "TLS_PERF_MEASURE_SECONDS")
        let settleTimeoutSeconds = try Self.positiveDouble(
            environment["TLS_PERF_SETTLE_TIMEOUT_SECONDS"] ?? "60",
            name: "TLS_PERF_SETTLE_TIMEOUT_SECONDS")
        guard warmupSeconds <= 86_400,
              measureSeconds <= 86_400,
              settleTimeoutSeconds <= 86_400,
              warmupSeconds * Double(rate) <= 10_000_000,
              measureSeconds * Double(rate) <= 10_000_000 else {
            throw InputError.invalid("workload_bounds")
        }
        let runID = try required("TLS_PERF_RUN_ID")
        guard runID.utf8.count <= 128,
              !runID.contains("\0"),
              runID.rangeOfCharacter(from: .newlines) == nil else {
            throw InputError.invalid("TLS_PERF_RUN_ID")
        }

        self.sdk = sdk
        self.mode = mode
        self.endpoint = endpoint
        self.rate = rate
        self.warmupSeconds = warmupSeconds
        self.measureSeconds = measureSeconds
        self.settleTimeoutSeconds = settleTimeoutSeconds
        self.runID = runID
    }

    private static func positiveDouble(_ text: String, name: String) throws -> Double {
        guard let value = Double(text), value.isFinite, value > 0 else {
            throw InputError.invalid(name)
        }
        return value
    }
}

private enum InputError: Error {
    case invalid(String)
}

private final class TLSResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var success = 0
    private var failure = 0
    private var rawBytes = 0

    func record(_ result: SendResult) {
        lock.lock()
        if result.status == .success {
            success += 1
        } else {
            failure += 1
        }
        rawBytes += result.rawBytes
        lock.unlock()
    }

    func snapshot() -> TerminalSnapshot {
        lock.lock()
        let value = TerminalSnapshot(
            success: success,
            failure: failure,
            rawBytes: rawBytes)
        lock.unlock()
        return value
    }
}

private struct TerminalSnapshot: Equatable {
    let success: Int
    let failure: Int
    let rawBytes: Int
}

private final class PerformanceRunner: @unchecked Sendable {
    private var tlsProducer: Producer?
    private var slsClient: SLSBenchmarkClient?

    func start() {
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let input = try PerformanceInput()
                try await run(input)
            } catch {
                writeFailureResult()
            }
        }
    }

    private func run(_ input: PerformanceInput) async throws {
        let totalWarmup = Int((input.warmupSeconds * Double(input.rate)).rounded(.down))
        let totalMeasured = Int((input.measureSeconds * Double(input.rate)).rounded(.down))
        guard totalWarmup > 0, totalMeasured > 0 else {
            throw InputError.invalid("workload_count")
        }
        let totalExpected = totalWarmup + totalMeasured
        let persistent = input.mode == .persistent
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)

        let tlsCollector = TLSResultCollector()
        if input.sdk == .tls {
            let configuration = try ProducerConfiguration(
                batch: BatchConfiguration(
                    maxLogCount: 1024,
                    maxRawBytes: 1024 * 1024,
                    linger: 3),
                buffer: BufferConfiguration(
                    maxBytes: 64 * 1024 * 1024,
                    fullPolicy: .reject),
                sendConcurrency: 1,
                compression: .lz4,
                persistence: persistent ? .buffered : .memory,
                connectTimeout: 10,
                requestTimeout: 15,
                metadata: ProducerMetadata(source: "iOS"),
                maxLogAge: 7 * 24 * 60 * 60,
                expiredLogPolicy: .rewriteTimestamp,
                unauthorizedPolicy: .retain,
                automaticLifecycleHandling: false,
                producerID: persistent ? "tls-performance" : nil,
                destination: Destination(
                    endpoint: input.endpoint,
                    region: "cn-beijing",
                    projectID: "performance-project",
                    topicID: "performance-topic"))
            tlsProducer = try await Producer.open(
                configuration: configuration,
                credentials: Credentials(
                    accessKeyID: "performance-test-ak",
                    accessKeySecret: "performance-test-sk"),
                onSendResult: { result in
                    tlsCollector.record(result)
                })
        } else {
            let path = documents.appendingPathComponent("sls-performance.dat").path
            guard let client = SLSBenchmarkClient(
                endpoint: input.endpoint,
                persistent: persistent,
                persistentPath: path) else {
                throw InputError.invalid("sls_configuration")
            }
            slsClient = client
        }

        var latenciesNanoseconds: [Int64] = []
        latenciesNanoseconds.reserveCapacity(totalMeasured)
        var inputConstructionLatenciesNanoseconds: [Int64] = []
        inputConstructionLatenciesNanoseconds.reserveCapacity(totalMeasured)
        var admissionSuccess = 0
        var admissionFailure = 0
        var measurementAdmissionSuccess = 0
        var measurementAdmissionFailure = 0
        var measurementStartEpochMilliseconds: Int64 = 0
        let intervalNanoseconds = 1_000_000_000.0 / Double(input.rate)
        let scheduleStart = DispatchTime.now().uptimeNanoseconds

        for index in 0..<totalExpected {
            let target = scheduleStart + UInt64(Double(index) * intervalNanoseconds)
            sleepUntil(uptimeNanoseconds: target)
            if index == totalWarmup {
                measurementStartEpochMilliseconds = epochMilliseconds()
            }

            let immediate = index == totalExpected - 1
            let started: UInt64
            let elapsed: UInt64
            let inputConstructionStarted = DispatchTime.now().uptimeNanoseconds
            let inputConstructionElapsed: UInt64
            let accepted: Bool
            if input.sdk == .tls {
                guard let producer = tlsProducer else {
                    throw InputError.invalid("tls_producer")
                }
                let event = makeTLSEvent(index: index)
                inputConstructionElapsed =
                    DispatchTime.now().uptimeNanoseconds - inputConstructionStarted
                started = DispatchTime.now().uptimeNanoseconds
                do {
                    try producer.add(event, mode: immediate ? .immediate : .normal)
                    accepted = true
                } catch {
                    accepted = false
                }
                elapsed = DispatchTime.now().uptimeNanoseconds - started
            } else {
                guard let client = slsClient else {
                    throw InputError.invalid("sls_client")
                }
                let log = client.prepareLog(index: UInt(index))
                inputConstructionElapsed =
                    DispatchTime.now().uptimeNanoseconds - inputConstructionStarted
                started = DispatchTime.now().uptimeNanoseconds
                accepted = client.add(log: log, immediate: immediate)
                elapsed = DispatchTime.now().uptimeNanoseconds - started
            }

            if accepted {
                admissionSuccess += 1
            } else {
                admissionFailure += 1
            }
            if index >= totalWarmup {
                inputConstructionLatenciesNanoseconds.append(
                    Int64(inputConstructionElapsed))
                latenciesNanoseconds.append(Int64(elapsed))
                if accepted {
                    measurementAdmissionSuccess += 1
                } else {
                    measurementAdmissionFailure += 1
                }
            }
        }
        let measurementEndEpochMilliseconds = epochMilliseconds()

        var lifecycleClose = "not_applicable"
        if let tlsProducer {
            do {
                try await tlsProducer.close(timeout: 30)
                lifecycleClose = "success"
            } catch {
                lifecycleClose = "failure"
            }
        } else {
            // Deliberately do not invoke AliyunLogProducer 4.3.4 destroy; see
            // SLSBenchmarkClient.m. Process isolation is part of the runner.
            lifecycleClose = "skipped_known_sls_4_3_4_destroy_uaf"
        }

        let snapshotProvider: () -> TerminalSnapshot = { [tlsCollector, weak self] in
            if input.sdk == .tls {
                return tlsCollector.snapshot()
            }
            guard let values = self?.slsClient?.terminalSnapshot() else {
                return TerminalSnapshot(success: 0, failure: 0, rawBytes: 0)
            }
            return TerminalSnapshot(
                success: values["success"]?.intValue ?? 0,
                failure: values["failure"]?.intValue ?? 0,
                rawBytes: values["rawBytes"]?.intValue ?? 0)
        }
        let terminal = await waitForStableTerminalResults(
            timeout: input.settleTimeoutSeconds,
            snapshot: snapshotProvider)

        let result: [String: Any] = [
            "schemaVersion": 2,
            "status": "completed",
            "sdk": input.sdk.rawValue,
            "mode": input.mode.rawValue,
            "rate": input.rate,
            "warmupSeconds": input.warmupSeconds,
            "measureSeconds": input.measureSeconds,
            "runID": input.runID,
            "logicalBytesPerLog": 1024,
            "fieldCount": 10,
            "compression": "lz4",
            "sendConcurrency": 1,
            "batchMaxLogCount": 1024,
            "batchMaxRawBytes": 1024 * 1024,
            "batchLingerMilliseconds": 3000,
            "expectedTotalAdmissions": totalExpected,
            "expectedMeasuredAdmissions": totalMeasured,
            "admissionSuccess": admissionSuccess,
            "admissionFailure": admissionFailure,
            "measurementAdmissionSuccess": measurementAdmissionSuccess,
            "measurementAdmissionFailure": measurementAdmissionFailure,
            "measurementStartEpochMilliseconds": measurementStartEpochMilliseconds,
            "measurementEndEpochMilliseconds": measurementEndEpochMilliseconds,
            "inputConstructionLatenciesNanoseconds":
                inputConstructionLatenciesNanoseconds,
            "latenciesNanoseconds": latenciesNanoseconds,
            "terminalSuccess": terminal.success,
            "terminalFailure": terminal.failure,
            "terminalRawBytes": terminal.rawBytes,
            "lifecycleClose": lifecycleClose,
        ]
        try writeResult(result)
    }

    private func makeTLSEvent(index: Int) -> LogEvent {
        var contents: [String: LogValue] = [:]
        contents.reserveCapacity(10)
        let prefix = String(format: "%012d", index)
        for field in 0..<10 {
            let key = "k\(field)"
            let valueLength = field < 4 ? 101 : 100
            let fieldPrefix = field == 0 ? prefix : ""
            let padding = String(repeating: "x", count: valueLength - fieldPrefix.utf8.count)
            contents[key] = .string(fieldPrefix + padding)
        }
        return LogEvent(contents: contents)
    }

    private func sleepUntil(uptimeNanoseconds target: UInt64) {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < target else { return }
            let remaining = Double(target - now) / 1_000_000_000
            Thread.sleep(forTimeInterval: remaining)
        }
    }

    private func waitForStableTerminalResults(
        timeout: Double,
        snapshot: @escaping () -> TerminalSnapshot
    ) async -> TerminalSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = snapshot()
        var stableSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let current = snapshot()
            if current != previous {
                previous = current
                stableSince = Date()
            }
            if current.success + current.failure > 0,
               Date().timeIntervalSince(stableSince) >= 3.5 {
                return current
            }
        }
        return snapshot()
    }

    private func epochMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private func writeFailureResult() {
        try? writeResult([
            "schemaVersion": 2,
            "status": "failed",
            "failureCode": "run_failed",
        ])
    }

    private func writeResult(_ result: [String: Any]) throws {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let data = try JSONSerialization.data(
            withJSONObject: result,
            options: [.sortedKeys])
        try data.write(
            to: documents.appendingPathComponent("performance-result.json"),
            options: [.atomic])
    }
}
