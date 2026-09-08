// swift-tools-version: 5.8
//
// VolcengineTLSProducer SwiftPM package manifest.
// Swift 5.8 syntax is retained for toolchains compatible with iOS 13 and the
// macOS 10.15 deployment contract. Apple Silicon binaries naturally start at
// macOS 11.0.

import PackageDescription

let package = Package(
    name: "VolcengineTLSProducer",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        // VolcengineTLSProducer is the only supported public product.
        .library(name: "VolcengineTLSProducer", targets: ["VolcengineTLSProducer"]),
    ],
    targets: [
        // Vendored C sources and the Objective-C bridge are private to the
        // public Producer API.
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
            name: "ProducerIntegrationTests",
            dependencies: ["VolcengineTLSProducer", "TLSProducerBridge"],
            path: "Producer/Tests/ProducerIntegrationTests"
        ),
    ]
)
