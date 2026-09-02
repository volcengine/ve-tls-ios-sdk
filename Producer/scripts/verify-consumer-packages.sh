#!/usr/bin/env bash
#
# verify-consumer-packages.sh — verify the actual iOS package consumption
# paths. This script deliberately does not run `swift test` on the host:
# Package.swift declares iOS as the product platform, so a host test run is
# neither an iOS test nor valid evidence for the iOS 13 contract.
#
# On macOS, runs:
#   1. minimum-iOS declaration and privacy/resource inspection
#   2. strict Swift 6 library builds for iOS 13 Simulator and generic device
#   3. external temporary SwiftPM consumer builds for Simulator and generic
#      iPhoneOS; the final iPhoneOS Mach-O must retain a minimum OS of 13.0
#   4. xcodebuild test on an available iOS Simulator destination
#   5. CocoaPods manifest/resource inspection and pod lib lint (when `pod`
#      exists)
#
# Usage: verify-consumer-packages.sh [xcode-scheme]
# Environment:
#   IOS_SIMULATOR_DESTINATION  explicit xcodebuild destination override
#   IOS_SIMULATOR_ARCH         default arm64
#   IOS_DEPLOYMENT_TARGET      SwiftPM minimum iOS target, default 13.0
#
# No skipped or blocked step is presented as a test pass. The script exits
# non-zero when a required tool/target exists but its verification fails, or
# when the host cannot provide the requested simulator/package evidence.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

SCHEME="${1:-VolcengineTLSProducer}"
MINIMUM_IOS_TARGET="13.0"
PRODUCER_RELEASE_VERSION="2.0.0"
PRODUCER_RELEASE_TAG="v${PRODUCER_RELEASE_VERSION}"
overall=0
ran=0
blocked=0

mark_fail() {
    echo "FAIL: $1"
    overall=1
}

mark_blocked() {
    echo "BLOCKED: $1"
    blocked=1
    overall=1
}

check_minimum_ios_contract() {
    local requested_target="${IOS_DEPLOYMENT_TARGET:-${MINIMUM_IOS_TARGET}}"
    echo "== minimum iOS contract =="

    if [[ "${requested_target}" != "${MINIMUM_IOS_TARGET}" ]]; then
        mark_fail "IOS_DEPLOYMENT_TARGET must be ${MINIMUM_IOS_TARGET} for the minimum-version gate (got ${requested_target})."
        return
    fi
    if grep -Eq 'platforms:[[:space:]]*\[[[:space:]]*\.iOS\(\.v13\)[[:space:]]*\]' "${REPO_ROOT}/Package.swift"; then
        echo "PASS: SwiftPM minimum deployment target is iOS ${MINIMUM_IOS_TARGET}."
    else
        mark_fail "Package.swift does not declare the frozen iOS ${MINIMUM_IOS_TARGET} minimum."
    fi
    if grep -Eq "s\.ios\.deployment_target[[:space:]]*=[[:space:]]*'13\.0'" "${REPO_ROOT}/VolcengineTLSProducer.podspec"; then
        echo "PASS: CocoaPods minimum deployment target is iOS ${MINIMUM_IOS_TARGET}."
    else
        mark_fail "VolcengineTLSProducer.podspec does not declare the frozen iOS ${MINIMUM_IOS_TARGET} minimum."
    fi
}

check_release_version_contract() {
    local podspec="${REPO_ROOT}/VolcengineTLSProducer.podspec"
    echo "== Producer release version contract =="

    if grep -Eq "s\.version[[:space:]]*=[[:space:]]*'${PRODUCER_RELEASE_VERSION}'" "${podspec}"; then
        echo "PASS: CocoaPods Producer version is ${PRODUCER_RELEASE_VERSION}."
    else
        mark_fail "VolcengineTLSProducer.podspec does not declare Producer ${PRODUCER_RELEASE_VERSION}."
    fi

    if grep -Fq ':tag => "v#{s.version}"' "${podspec}"; then
        echo "PASS: CocoaPods source tag resolves to ${PRODUCER_RELEASE_TAG}."
    else
        mark_fail "VolcengineTLSProducer.podspec does not derive the v-prefixed source tag from s.version."
    fi
}

check_privacy_manifest() {
    local manifest="${REPO_ROOT}/Producer/Sources/VolcengineTLSProducer/Resources/PrivacyInfo.xcprivacy"
    local bridge_module_map="${REPO_ROOT}/Producer/scripts/TLSProducerBridge.modulemap"
    echo "== privacy manifest/resource configuration =="
    if [[ ! -f "${manifest}" ]]; then
        mark_fail "PrivacyInfo.xcprivacy not found at ${manifest}."
        return
    fi

    if command -v plutil >/dev/null 2>&1; then
        if plutil -lint "${manifest}" >/dev/null; then
            echo "PASS: PrivacyInfo.xcprivacy is a valid plist."
        else
            mark_fail "PrivacyInfo.xcprivacy failed plutil -lint."
        fi
    else
        echo "SKIP: plutil not found; plist syntax requires macOS."
    fi

    if grep -q 'NSPrivacyAccessedAPICategoryFileTimestamp' "${manifest}" && \
       grep -q '<string>C617.1</string>' "${manifest}"; then
        echo "PASS: PrivacyInfo declares stat(2) file metadata access as FileTimestamp/C617.1."
    else
        mark_fail "PrivacyInfo.xcprivacy is missing FileTimestamp/C617.1 for the persistent Core's stat(2) use."
    fi

    if command -v swift >/dev/null 2>&1; then
        local dump cache dump_file
        dump_file="$(mktemp "${TMPDIR:-/tmp}/tls-package-dump.XXXXXX")"
        cache="$(mktemp -d "${TMPDIR:-/tmp}/tls-package-cache.XXXXXX")"
        if CLANG_MODULE_CACHE_PATH="${cache}" swift package dump-package >"${dump_file}" 2>&1; then
            if grep -q 'PrivacyInfo.xcprivacy' "${dump_file}"; then
                echo "PASS: SwiftPM declares PrivacyInfo.xcprivacy as a processed resource."
            else
                mark_fail "SwiftPM dump-package did not contain PrivacyInfo.xcprivacy."
            fi
        else
            mark_fail "swift package dump-package failed; package/resource configuration is unverified."
            sed -n '1,80p' "${dump_file}"
        fi
        rm -rf "${dump_file}" "${cache}"
    else
        echo "SKIP: swift not found; SwiftPM resource configuration is unverified."
    fi

    if command -v pod >/dev/null 2>&1; then
        local pod_spec
        pod_spec="$(mktemp "${TMPDIR:-/tmp}/tls-pod-spec.XXXXXX")"
        if pod ipc spec "${REPO_ROOT}/VolcengineTLSProducer.podspec" >"${pod_spec}" 2>&1; then
            if grep -q 'PrivacyInfo.xcprivacy' "${pod_spec}" && grep -q 'resource_bundles' "${pod_spec}"; then
                echo "PASS: CocoaPods declares PrivacyInfo.xcprivacy in a resource bundle."
            else
                mark_fail "pod ipc spec output did not contain the PrivacyInfo resource bundle."
            fi
        else
            mark_fail "pod ipc spec failed for VolcengineTLSProducer.podspec."
            sed -n '1,80p' "${pod_spec}"
        fi
        rm -f "${pod_spec}"
    else
        mark_blocked "CocoaPods is not installed; pod resource-bundle configuration and lint are unverified."
    fi

    if [[ -f "${bridge_module_map}" ]] && \
       grep -q 'module TLSProducerBridge' "${bridge_module_map}" && \
       grep -q 'TLSProducerBridge/include/TLSProducerBridge.h' "${bridge_module_map}"; then
        echo "PASS: CocoaPods private TLSProducerBridge module map is present."
    else
        mark_fail "CocoaPods private TLSProducerBridge module map is missing or incomplete."
    fi
}

resolve_ios_sdk() {
    IOS_SDK=""
    IOS_SDK_VERSION=""
    if ! command -v xcrun >/dev/null 2>&1; then
        return 1
    fi
    if ! IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"; then
        return 1
    fi
    if ! IOS_SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null)"; then
        return 1
    fi
    [[ -n "${IOS_SDK}" && -n "${IOS_SDK_VERSION}" ]]
}

resolve_iphoneos_sdk() {
    IPHONEOS_SDK=""
    IPHONEOS_SDK_VERSION=""
    if ! command -v xcrun >/dev/null 2>&1; then
        return 1
    fi
    if ! IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"; then
        return 1
    fi
    if ! IPHONEOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)"; then
        return 1
    fi
    [[ -n "${IPHONEOS_SDK}" && -n "${IPHONEOS_SDK_VERSION}" ]]
}

run_swiftpm_ios_build() {
    echo "== SwiftPM iOS Simulator library build =="
    if ! command -v swift >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
        echo "SKIP: swift/xcrun not found; iOS Simulator build requires Xcode."
        return
    fi

    local build_root cache arch deployment_target triple
    if ! resolve_ios_sdk; then
        mark_blocked "iPhoneSimulator SDK could not be resolved by xcrun."
        return
    fi
    arch="${IOS_SIMULATOR_ARCH:-arm64}"
    deployment_target="${IOS_DEPLOYMENT_TARGET:-${MINIMUM_IOS_TARGET}}"
    if [[ ! "${deployment_target}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        mark_fail "invalid IOS_DEPLOYMENT_TARGET: ${deployment_target}."
        return
    fi
    triple="${arch}-apple-ios${deployment_target}-simulator"
    build_root="$(mktemp -d "${TMPDIR:-/tmp}/tls-swiftpm-ios-build.XXXXXX")"
    cache="$(mktemp -d "${TMPDIR:-/tmp}/tls-swiftpm-ios-cache.XXXXXX")"
    ran=1
    if CLANG_MODULE_CACHE_PATH="${cache}" swift build \
        --package-path "${REPO_ROOT}" \
        --scratch-path "${build_root}" \
        --target VolcengineTLSProducer \
        --sdk "${IOS_SDK}" \
        --triple "${triple}" \
        -Xswiftc -swift-version -Xswiftc 6; then
        echo "PASS: SwiftPM strict Swift 6 iOS Simulator library build (${triple}, SDK ${IOS_SDK_VERSION})."
    else
        mark_fail "SwiftPM iOS Simulator library build failed (${triple})."
    fi
    rm -rf "${build_root}" "${cache}"
}

run_swiftpm_ios_device_build() {
    echo "== SwiftPM generic iOS device library build =="
    if ! command -v swift >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
        echo "SKIP: swift/xcrun not found; generic iOS device build requires Xcode."
        return
    fi

    local build_root cache deployment_target triple
    if ! resolve_iphoneos_sdk; then
        mark_blocked "iPhoneOS SDK could not be resolved by xcrun."
        return
    fi
    deployment_target="${IOS_DEPLOYMENT_TARGET:-${MINIMUM_IOS_TARGET}}"
    if [[ ! "${deployment_target}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        mark_fail "invalid IOS_DEPLOYMENT_TARGET: ${deployment_target}."
        return
    fi
    triple="arm64-apple-ios${deployment_target}"
    build_root="$(mktemp -d "${TMPDIR:-/tmp}/tls-swiftpm-device-build.XXXXXX")"
    cache="$(mktemp -d "${TMPDIR:-/tmp}/tls-swiftpm-device-cache.XXXXXX")"
    ran=1
    if CLANG_MODULE_CACHE_PATH="${cache}" swift build \
        --package-path "${REPO_ROOT}" \
        --scratch-path "${build_root}" \
        --target VolcengineTLSProducer \
        --sdk "${IPHONEOS_SDK}" \
        --triple "${triple}" \
        -Xswiftc -swift-version -Xswiftc 6; then
        echo "PASS: SwiftPM strict Swift 6 generic iOS device library build (${triple}, SDK ${IPHONEOS_SDK_VERSION}); no physical device is required."
    else
        mark_fail "SwiftPM generic iOS device library build failed (${triple})."
    fi
    rm -rf "${build_root}" "${cache}"
}

verify_macho_minimum_ios() {
    local binary="$1"
    local expected_platform="$2"
    local expected_target="$3"
    local build_info platform minos

    if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find vtool >/dev/null 2>&1; then
        mark_blocked "vtool is unavailable; final consumer Mach-O minimum OS cannot be verified."
        return 1
    fi
    if ! build_info="$(xcrun vtool -show-build "${binary}" 2>&1)"; then
        echo "${build_info}" >&2
        mark_fail "vtool could not inspect the final external consumer binary."
        return 1
    fi
    platform="$(printf '%s\n' "${build_info}" | awk '$1 == "platform" { print $2; exit }')"
    minos="$(printf '%s\n' "${build_info}" | awk '$1 == "minos" { print $2; exit }')"
    if [[ "${platform}" != "${expected_platform}" ]]; then
        echo "${build_info}" >&2
        mark_fail "external consumer Mach-O platform is ${platform:-missing}, expected ${expected_platform}."
        return 1
    fi
    case "${minos}" in
        "${expected_target}"|"${expected_target}.0")
            echo "PASS: external consumer Mach-O records platform ${platform} and minos ${minos}."
            ;;
        *)
            echo "${build_info}" >&2
            mark_fail "external consumer Mach-O minos is ${minos:-missing}, expected ${expected_target}."
            return 1
            ;;
    esac
}

run_external_swiftpm_consumer() {
    echo "== external SwiftPM consumer build =="
    if ! command -v xcodebuild >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
        echo "SKIP: xcodebuild/xcrun not found; external consumer build requires Xcode."
        return
    fi
    if ! resolve_ios_sdk; then
        mark_blocked "iPhoneSimulator SDK could not be resolved for external consumer build."
        return
    fi

    local consumer_root consumer_sim_build consumer_device_build consumer_cache
    local package_identity arch deployment_target sim_triple device_triple
    consumer_root="$(mktemp -d "${TMPDIR:-/tmp}/tls-swiftpm-consumer.XXXXXX")"
    consumer_sim_build="$(mktemp -d "${TMPDIR:-/tmp}/tls-swiftpm-consumer-sim-build.XXXXXX")"
    consumer_device_build="$(mktemp -d "${TMPDIR:-/tmp}/tls-swiftpm-consumer-device-build.XXXXXX")"
    consumer_cache="$(mktemp -d "${TMPDIR:-/tmp}/tls-swiftpm-consumer-cache.XXXXXX")"
    package_identity="$(basename "${REPO_ROOT}")"
    arch="${IOS_SIMULATOR_ARCH:-arm64}"
    deployment_target="${IOS_DEPLOYMENT_TARGET:-${MINIMUM_IOS_TARGET}}"
    if [[ ! "${deployment_target}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        mark_fail "invalid IOS_DEPLOYMENT_TARGET: ${deployment_target}."
        rm -rf "${consumer_root}" "${consumer_sim_build}" "${consumer_device_build}" "${consumer_cache}"
        return
    fi
    sim_triple="${arch}-apple-ios${deployment_target}-simulator"
    device_triple="arm64-apple-ios${deployment_target}"

    mkdir -p "${consumer_root}/Sources/TLSConsumerSmoke"
    # This fixture is generated under /tmp at verification time; it is not a
    # checked-in source file and is removed after the build.
    printf '%s\n' \
        '// swift-tools-version: 5.8' \
        'import PackageDescription' \
        '' \
        'let package = Package(' \
        '    name: "TLSConsumerSmoke",' \
        '    platforms: [.iOS(.v13)],' \
        '    dependencies: [' \
        "        .package(path: \"${REPO_ROOT}\")" \
        '    ],' \
        '    targets: [' \
        '        .executableTarget(' \
        '            name: "TLSConsumerSmoke",' \
        '            dependencies: [' \
        "                .product(name: \"VolcengineTLSProducer\", package: \"${package_identity}\")" \
        '            ]' \
        '        )' \
        '    ]' \
        ')' > "${consumer_root}/Package.swift"
    printf '%s\n' \
        'import VolcengineTLSProducer' \
        '' \
        '// Type-check the real public async lifecycle; no network code is run.' \
        'func compilePublicLifecycle() async throws {' \
        '    let destination = Destination(' \
        '        endpoint: "https://example.com",' \
        '        region: "cn-beijing",' \
        '        projectID: "project",' \
        '        topicID: "topic")' \
        '    let configuration = try ProducerConfiguration(destination: destination)' \
        '    let credentials = Credentials(accessKeyID: "ak", accessKeySecret: "sk")' \
        '    let producer = try await Producer.open(' \
        '        configuration: configuration,' \
        '        credentials: credentials)' \
        '    try await producer.close(timeout: 1)' \
        '}' \
        '' \
        '// Also type-check the common strict-concurrency call pattern.' \
        'func compileDetachedOpen(configuration: ProducerConfiguration, credentials: Credentials) async throws {' \
        '    let task = Task.detached {' \
        '        try await Producer.open(configuration: configuration, credentials: credentials)' \
        '    }' \
        '    let producer = try await task.value' \
        '    try await producer.close(timeout: 1)' \
        '}' \
        > "${consumer_root}/Sources/TLSConsumerSmoke/main.swift"

    ran=1
    if (cd "${consumer_root}" && CLANG_MODULE_CACHE_PATH="${consumer_cache}" xcodebuild \
        -scheme TLSConsumerSmoke \
        -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "${consumer_sim_build}" \
        build \
        CODE_SIGNING_ALLOWED=NO \
        ARCHS="${arch}" \
        ONLY_ACTIVE_ARCH=YES \
        IPHONEOS_DEPLOYMENT_TARGET="${deployment_target}" \
        SWIFT_VERSION=6 \
        SWIFT_STRICT_CONCURRENCY=complete); then
        local consumer_binary resource_copy
        resource_copy="$(find "${consumer_sim_build}" -type f -name 'PrivacyInfo.xcprivacy' -print -quit 2>/dev/null || true)"
        if [[ -n "${resource_copy}" ]]; then
            echo "PASS: external strict Swift 6 Simulator consumer built the public lifecycle (requested ${sim_triple}, SDK ${IOS_SDK_VERSION}); dependency settings were accepted and the privacy resource was copied. The Simulator Mach-O minimum is toolchain-controlled and is not used as iOS 13 device evidence."
        else
            mark_fail "external SwiftPM build succeeded but PrivacyInfo.xcprivacy was not found in the built resource output."
        fi
        consumer_binary="$(find "${consumer_sim_build}" -type f -name 'TLSConsumerSmoke' ! -path '*.dSYM/*' -print -quit 2>/dev/null || true)"
        if [[ -n "${consumer_binary}" ]]; then
            if "${SCRIPT_DIR}/verify-public-symbols.sh" "${consumer_binary}"; then
                echo "PASS: linked external SwiftPM Simulator consumer does not export private Core/LZ4 symbols."
            else
                mark_fail "linked external SwiftPM Simulator consumer exported private Core/LZ4 symbols."
            fi
        else
            mark_fail "external SwiftPM Simulator build succeeded but its final linked consumer binary was not found."
        fi
    else
        mark_fail "external SwiftPM Simulator consumer xcodebuild failed (${sim_triple}); this catches dependency unsafeFlags and public import regressions."
    fi

    if (cd "${consumer_root}" && CLANG_MODULE_CACHE_PATH="${consumer_cache}" xcodebuild \
        -scheme TLSConsumerSmoke \
        -configuration Debug \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "${consumer_device_build}" \
        build \
        CODE_SIGNING_ALLOWED=NO \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        IPHONEOS_DEPLOYMENT_TARGET="${deployment_target}" \
        SWIFT_VERSION=6 \
        SWIFT_STRICT_CONCURRENCY=complete); then
        local device_binary
        device_binary="$(find "${consumer_device_build}" -type f -name 'TLSConsumerSmoke' ! -path '*.dSYM/*' -print -quit 2>/dev/null || true)"
        if [[ -n "${device_binary}" ]]; then
            if "${SCRIPT_DIR}/verify-public-symbols.sh" "${device_binary}"; then
                echo "PASS: linked external SwiftPM iPhoneOS consumer does not export private Core/LZ4 symbols."
            else
                mark_fail "linked external SwiftPM iPhoneOS consumer exported private Core/LZ4 symbols."
            fi
            verify_macho_minimum_ios "${device_binary}" "IOS" "${MINIMUM_IOS_TARGET}" || true
        else
            mark_fail "external SwiftPM iPhoneOS build succeeded but its final linked consumer binary was not found."
        fi
    else
        mark_fail "external SwiftPM iPhoneOS consumer xcodebuild failed (${device_triple}); the final iOS ${MINIMUM_IOS_TARGET} artifact contract is unverified."
    fi
    rm -rf "${consumer_root}" "${consumer_sim_build}" "${consumer_device_build}" "${consumer_cache}"
}

find_simulator_destination() {
    if [[ -n "${IOS_SIMULATOR_DESTINATION:-}" ]]; then
        printf '%s' "${IOS_SIMULATOR_DESTINATION}"
        return 0
    fi
    if ! command -v xcrun >/dev/null 2>&1; then
        return 1
    fi

    local devices device_id
    if ! devices="$(xcrun simctl list devices available 2>&1)"; then
        echo "${devices}" >&2
        return 1
    fi
    device_id="$(printf '%s\n' "${devices}" | grep -Eo '[A-Fa-f0-9-]{36}' | head -n1 || true)"
    if [[ -z "${device_id}" ]]; then
        return 1
    fi
    printf 'platform=iOS Simulator,id=%s' "${device_id}"
}

run_xcodebuild_tests() {
    echo "== xcodebuild iOS Simulator tests =="
    if ! command -v xcodebuild >/dev/null 2>&1; then
        echo "SKIP: xcodebuild not found; simulator tests require Xcode."
        return
    fi

    local destination derived_data simctl_error package_root
    simctl_error="$(mktemp "${TMPDIR:-/tmp}/tls-simctl-error.XXXXXX")"
    if ! destination="$(find_simulator_destination 2>"${simctl_error}")"; then
        if [[ -s "${simctl_error}" ]]; then
            sed -n '1,40p' "${simctl_error}" >&2
        fi
        rm -f "${simctl_error}"
        mark_blocked "no available iOS Simulator destination (set IOS_SIMULATOR_DESTINATION or start a simulator)."
        return
    fi
    rm -f "${simctl_error}"
    # A repository checkout also contains the legacy VeTLSiOSSDK workspace.
    # Running xcodebuild from that directory makes it select the legacy
    # workspace and report a missing package scheme. Exercise the package from
    # an isolated temporary checkout containing only Package.swift + Producer.
    package_root="$(mktemp -d "${TMPDIR:-/tmp}/tls-xcode-package.XXXXXX")"
    if ! cp "${REPO_ROOT}/Package.swift" "${package_root}/Package.swift" || \
       ! cp -R "${REPO_ROOT}/Producer" "${package_root}/Producer"; then
        rm -rf "${package_root}"
        mark_fail "could not prepare an isolated Swift package checkout for xcodebuild."
        return
    fi
    derived_data="$(mktemp -d "${TMPDIR:-/tmp}/tls-xcodebuild-tests.XXXXXX")"
    ran=1
    if (cd "${package_root}" && xcodebuild \
            -scheme "${SCHEME}" \
            -destination "${destination}" \
            -derivedDataPath "${derived_data}" \
            test \
            CODE_SIGNING_ALLOWED=NO); then
        echo "PASS: xcodebuild tests executed on ${destination}."
    else
        mark_fail "xcodebuild tests failed on ${destination}."
    fi
    rm -rf "${derived_data}" "${package_root}"
}

run_pod_lint() {
    echo "== CocoaPods lint =="
    if ! command -v pod >/dev/null 2>&1; then
        echo "SKIP: pod not found; run pod lib lint on a CocoaPods-enabled release host."
        return
    fi
    ran=1
    if pod lib lint "${REPO_ROOT}/VolcengineTLSProducer.podspec" --allow-warnings; then
        echo "PASS: pod lib lint completed."
    else
        mark_fail "pod lib lint failed."
    fi
}

check_minimum_ios_contract
check_release_version_contract
check_privacy_manifest
run_swiftpm_ios_build
run_swiftpm_ios_device_build
run_external_swiftpm_consumer
run_xcodebuild_tests
run_pod_lint

echo ""
if [[ "${overall}" -eq 0 && "${ran}" -eq 0 && "${blocked}" -eq 0 ]]; then
    echo "SKIP: no package tools available on this host (needs macOS + Xcode + CocoaPods)."
elif [[ "${overall}" -eq 0 ]]; then
    echo "PASS: consumer package verification completed; every executed check passed."
else
    echo "FAIL: consumer package verification is incomplete or one or more checks failed."
fi
exit "${overall}"
