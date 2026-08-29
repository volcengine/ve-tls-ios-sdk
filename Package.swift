// swift-tools-version: 5.8
//
// VolcengineTLSProducer — SwiftPM package manifest (release candidate source).
//
// Frozen decisions: see Producer/DECISIONS.md and the implementation decision
// ledger (docs/research/tls-ios-producer-sdk-implementation-decision-ledger.md).
//
// Structure:
//   TLSProducerBridge     — vendored C Core + Objective-C internal bridge
//                           (one hidden-symbol Clang target; not a product)
//   VolcengineTLSProducer — Swift public API (the ONLY public product)
//   BridgeTests/Support   — BridgeTests-only support (FakeCoreAdapter/fixtures)
//   5 test targets        — Contract/Bridge/Transport/Persistence/ConsumerIntegration
//
// Evidence boundary: this manifest describes the source package. The iOS 13
// minimum is additionally enforced by compile/link and final Mach-O minos
// checks, supported toolchain builds, simulator runtime tests, and the package
// consumer checks under Producer/scripts/. An exact iOS 13 device is not a
// release prerequisite.
//
// Swift 5.8 manifest syntax only — no Swift 5.9+ features (e.g. `traits`).

import PackageDescription

let package = Package(
    name: "VolcengineTLSProducer",
    platforms: [.iOS(.v13)],
    products: [
        // The single supported public product. TLSProducerBridge is an
        // implementation target and is NOT published as a product. SwiftPM
        // may still make transitive target modules discoverable at compile
        // time; that does not make their declarations supported API.
        .library(name: "VolcengineTLSProducer", targets: ["VolcengineTLSProducer"]),
    ],
    targets: [
        // C Core v0.3.1 and Objective-C bridge share one package-internal
        // Clang target. Keeping them together lets the Core definitions use
        // hidden visibility without being localized before the bridge's
        // cross-object references are resolved. This keeps final consumer
        // Mach-O binaries free of bare ve_tls_* and LZ4 symbols.
        .target(
            name: "TLSProducerBridge",
            path: "Producer/Sources",
            exclude: ["VolcengineTLSProducer"],
            sources: ["CTLSProducerCore", "TLSProducerBridge"],
            publicHeadersPath: "TLSProducerBridge/include",
            cSettings: [
                .headerSearchPath("TLSProducerBridge"),
                .headerSearchPath("CTLSProducerCore/include"),
                .headerSearchPath("CTLSProducerCore/core/src"),
                .headerSearchPath("CTLSProducerCore/core/src/producer"),
                .headerSearchPath("CTLSProducerCore/third_party/lz4"),
                .define("VE_TLS_NO_CURL", to: "1"),
                .define("VE_TLS_HAVE_LZ4", to: "1"),
                .define("VE_TLS_PACKAGE_INTERNAL", to: "1"),
            ]
        ),

        // Swift public API — the only consumer-facing surface.
        .target(
            name: "VolcengineTLSProducer",
            dependencies: ["TLSProducerBridge"],
            path: "Producer/Sources/VolcengineTLSProducer",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),

        .testTarget(
            name: "ContractTests",
            dependencies: ["VolcengineTLSProducer"],
            path: "Producer/Tests/ContractTests"
        ),
        .testTarget(
            name: "BridgeTests",
            dependencies: ["VolcengineTLSProducer", "TLSProducerBridge"],
            path: "Producer/Tests/BridgeTests"
        ),
        .testTarget(
            name: "TransportTests",
            dependencies: ["TLSProducerBridge", "VolcengineTLSProducer"],
            path: "Producer/Tests/TransportTests"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["TLSProducerBridge", "VolcengineTLSProducer"],
            path: "Producer/Tests/PersistenceTests"
        ),
        .testTarget(
            name: "ConsumerIntegrationTests",
            dependencies: ["VolcengineTLSProducer", "TLSProducerBridge"],
            path: "Producer/Tests/ConsumerIntegrationTests"
        ),
    ]
)
