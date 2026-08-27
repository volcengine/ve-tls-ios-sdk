// swift-tools-version: 5.8
//
// VolcengineTLSProducer — SwiftPM package manifest (Development Preview).
//
// Frozen decisions: see Producer/DECISIONS.md and the implementation decision
// ledger (docs/research/tls-ios-producer-sdk-implementation-decision-ledger.md).
//
// Structure:
//   CTLSProducerCore      — C placeholder target (real Core blocked on release gate)
//   TLSProducerBridge     — Objective-C internal bridge (not a public product)
//   VolcengineTLSProducer — Swift public API (the ONLY public product)
//   ProducerTestSupport   — shared test support (FakeCoreAdapter; tests only)
//   5 test targets        — Contract/Bridge/Transport/Persistence/ConsumerIntegration
//
// Evidence boundary: this manifest is only validated on macOS with a Swift 5.8
// toolchain. The Linux dev machine has no Swift toolchain; compilation/test
// evidence is pending (see ledger §4). Do not claim Beta from this file alone.
//
// Swift 5.8 manifest syntax only — no Swift 5.9+ features (e.g. `traits`).

import PackageDescription

let package = Package(
    name: "VolcengineTLSProducer",
    platforms: [.iOS(.v13)],
    products: [
        // The single public product. TLSProducerBridge and CTLSProducerCore are
        // internal implementation details and are NOT published as products.
        .library(name: "VolcengineTLSProducer", targets: ["VolcengineTLSProducer"]),
    ],
    targets: [
        // C Core (ve-tls-c-sdk v0.3.1, vendored). Provides the persistent
        // producer engine: WAL, retry, batching, signing, LZ4 compression.
        // The real Core has passed the release gate (tag v0.3.1, commit
        // 08f33af, CI asan-ubsan/shared-abi/static-release green).
        // See Producer/CORE_VERSION for the frozen release record.
        .target(
            name: "CTLSProducerCore",
            path: "Producer/Sources/CTLSProducerCore",
            publicHeadersPath: "include",
            cSettings: [
                // Internal C Core headers (core/src/ and core/src/producer/)
                // and the vendored LZ4 namespace header.
                .headerSearchPath("core/src"),
                .headerSearchPath("core/src/producer"),
                .headerSearchPath("third_party/lz4"),
                // No curl on iOS; the C Core's curl adapter is guarded by
                // VE_TLS_HAVE_CURL and is not compiled.
                .define("VE_TLS_NO_CURL", to: "1"),
            ]
        ),

        // Objective-C bridge (package-internal). Wraps the C Core for the Swift
        // layer. Internal headers (Core/Bridge/Transport/Storage/Lifecycle) are
        // exported by the umbrella header so package test targets can exercise
        // them; the Bridge is not a public product, and the Swift target does
        // not re-export the Clang module, so consumers never see bare C types.
        .target(
            name: "TLSProducerBridge",
            dependencies: ["CTLSProducerCore"],
            path: "Producer/Sources/TLSProducerBridge",
            publicHeadersPath: "include",
            cSettings: [
                // Allow cross-directory quoted imports of internal bridge headers,
                // e.g. #import "Bridge/TLSBridgeFoo.h".
                .headerSearchPath("."),
            ]
        ),

        // Swift public API — the only consumer-facing surface.
        .target(
            name: "VolcengineTLSProducer",
            dependencies: ["TLSProducerBridge"],
            path: "Producer/Sources/VolcengineTLSProducer",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),

        // Shared test support (FakeCoreAdapter etc.). Regular (non-test) target
        // so it can be linked into multiple test targets. Lives under
        // Producer/Tests but is never shipped (excluded from the podspec).
        .target(
            name: "ProducerTestSupport",
            dependencies: ["VolcengineTLSProducer"],
            path: "Producer/Tests/ProducerTestSupport"
        ),

        .testTarget(
            name: "ContractTests",
            dependencies: ["VolcengineTLSProducer"],
            path: "Producer/Tests/ContractTests"
        ),
        .testTarget(
            name: "BridgeTests",
            dependencies: ["VolcengineTLSProducer", "TLSProducerBridge", "ProducerTestSupport", "CTLSProducerCore"],
            path: "Producer/Tests/BridgeTests"
        ),
        .testTarget(
            name: "TransportTests",
            dependencies: ["TLSProducerBridge", "ProducerTestSupport", "VolcengineTLSProducer"],
            path: "Producer/Tests/TransportTests"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["TLSProducerBridge", "ProducerTestSupport", "VolcengineTLSProducer"],
            path: "Producer/Tests/PersistenceTests"
        ),
        .testTarget(
            name: "ConsumerIntegrationTests",
            dependencies: ["VolcengineTLSProducer", "TLSProducerBridge"],
            path: "Producer/Tests/ConsumerIntegrationTests"
        ),
    ]
)
