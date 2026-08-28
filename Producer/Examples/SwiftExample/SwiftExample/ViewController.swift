//
//  ViewController.swift
//  SwiftExample
//
//  One-button demo of the VolcengineTLSProducer public API:
//  tap → open (once) → add(.immediate) → show SendResult.
//
//  DEVELOPMENT PREVIEW: `Producer.open` uses the Real C Core and can issue
//  real HTTPS requests. Replace the placeholders only with credentials and a
//  project/topic explicitly authorized for testing. This UI is not BOE,
//  device, or service-delivery evidence by itself.
//

import UIKit
import VolcengineTLSProducer

final class ViewController: UIViewController {

    // MARK: - Replace with your own TLS project/topic and credentials

    private let endpoint = "https://tls-cn-beijing.volces.com"
    private let region = "cn-beijing"
    private let projectID = "your-project-id"
    private let topicID = "your-topic-id"
    private let credentials = Credentials(
        accessKeyID: "your-access-key-id",
        accessKeySecret: "your-access-key-secret")

    // MARK: - UI

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Idle"
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    private let addButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Add Log", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        return button
    }()

    // MARK: - Producer state

    private var producer: Producer?
    private var tapCount = 0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    private func setupUI() {
        view.addSubview(statusLabel)
        view.addSubview(addButton)

        addButton.addTarget(self,
                            action: #selector(addLogTapped),
                            for: .touchUpInside)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            addButton.topAnchor.constraint(
                equalTo: statusLabel.bottomAnchor, constant: 24),
            addButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func addLogTapped() {
        Task { @MainActor in
            do {
                let producer = try await ensureProducer()
                tapCount += 1
                let event = LogEvent(contents: [
                    "level": .string("info"),
                    "message": .string("tap #\(tapCount)"),
                ])
                // `.immediate` seals the batch and wakes the sender. It is
                // still asynchronous: the call returns before the
                // SendResult callback fires.
                try producer.add(event, mode: .immediate)
                statusLabel.text = "Added log #\(tapCount), waiting for SendResult…"
            } catch {
                statusLabel.text = "Failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Producer

    /// Opens the producer lazily on first tap with a validated destination.
    /// `onSendResult` is delivered on the SDK callback queue (not main), so
    /// UI updates hop back to the main queue.
    private func ensureProducer() async throws -> Producer {
        if let producer {
            return producer
        }

        let destination = Destination(endpoint: endpoint,
                                      region: region,
                                      projectID: projectID,
                                      topicID: topicID)
        let configuration = try ProducerConfiguration(destination: destination)

        let producer = try await Producer.open(
            configuration: configuration,
            credentials: credentials
        ) { [weak self] result in
            let text: String
            switch result.status {
            case .success:
                text = "SendResult: success (raw=\(result.rawBytes), "
                    + "compressed=\(result.compressedBytes))"
            case .failure:
                text = "SendResult: failure "
                    + "(\(result.error?.errorCode ?? "unknown"))"
            }
            DispatchQueue.main.async {
                self?.statusLabel.text = text
            }
        }

        self.producer = producer
        return producer
    }
}
