#!/usr/bin/env bash
#
# Verify a real external pure Objective-C consumer of the Producer facade.
#
# The script creates all Xcode/CocoaPods consumer files below a private
# mktemp directory. It exercises both CocoaPods' default static-library
# integration and `use_frameworks! :linkage => :static`, builds the same
# Objective-C source for macOS and iOS Simulator, and runs the macOS command
# line consumer against its URLProtocol stub. No real credentials or business
# network are used.
#
# SwiftPM is probed as a real external Objective-C target through the package's
# Clang module (`@import VolcengineTLSProducer`). The probe never adds a
# hand-written header or search path. Any compile/link/runtime failure fails
# this verifier.
#
# Environment:
#   RUN_IOS_SIMULATOR=1  after a successful Simulator build, run the app on a
#                        currently booted iOS Simulator when possible.
#   IOS_SIMULATOR_UDID   select the booted Simulator explicitly when more than
#                        one device is available (recommended for CI).
#   SKIP_IOS=1           skip iOS Simulator builds.
#   SKIP_MACOS=1         skip macOS build/run checks.
#   SKIP_SWIFTPM=1       skip the SwiftPM module probe.
#   POD_SOURCE_MODE=git   install CocoaPods from a temporary Git snapshot
#                        (default; exercises CocoaPods' clean checkout path).
#   POD_SOURCE_MODE=path  install CocoaPods from the same temporary path snapshot.
#   KEEP_SUCCESS=1       keep successful temp projects for inspection.
#   POD_BIN/RUBY_BIN/XCODEBUILD_BIN/XCRUN_BIN override tool paths; otherwise
#   pod/ruby/xcodebuild/xcrun are discovered through PATH.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURE_DIR="${REPO_ROOT}/Producer/Tests/ObjectiveCConsumer"
POD_SOURCE_MODE="${POD_SOURCE_MODE:-git}"

if [[ -n "${POD_BIN:-}" ]]; then
    POD_BIN="${POD_BIN}"
else
    POD_BIN="$(command -v pod 2>/dev/null || true)"
fi
if [[ -n "${RUBY_BIN:-}" ]]; then
    RUBY_BIN="${RUBY_BIN}"
else
    RUBY_BIN="$(command -v ruby 2>/dev/null || true)"
fi
if [[ -n "${XCODEBUILD_BIN:-}" ]]; then
    XCODEBUILD_BIN="${XCODEBUILD_BIN}"
else
    XCODEBUILD_BIN="$(command -v xcodebuild || true)"
fi
if [[ -n "${XCRUN_BIN:-}" ]]; then
    XCRUN_BIN="${XCRUN_BIN}"
else
    XCRUN_BIN="$(command -v xcrun || true)"
fi
GIT_BIN="$(command -v git 2>/dev/null || true)"

overall=0
ran=0
blocked=0
task_root=""
keep_temp=0
pod_source_root=""
pod_source_commit=""

mark_fail() {
    echo "FAIL: $1"
    overall=1
}

mark_blocked() {
    echo "BLOCKED: $1"
    blocked=1
    overall=1
}

cleanup() {
    local exit_status=$?
    if [[ "${exit_status}" -ne 0 ]]; then
        overall=1
    fi
    if [[ -z "${task_root}" || ! -d "${task_root}" ]]; then
        return
    fi
    if [[ "${overall}" -eq 0 && "${keep_temp}" -eq 0 ]]; then
        rm -rf "${task_root}"
        return
    fi
    echo "INFO: preserving temporary consumer projects at ${task_root}"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: Objective-C CocoaPods consumer verification requires macOS/Xcode."
    exit 0
fi

preflight() {
    echo "== Objective-C consumer preflight =="
    case "${POD_SOURCE_MODE}" in
        git|path)
            echo "OK: CocoaPods source mode is ${POD_SOURCE_MODE}."
            ;;
        *)
            mark_fail "POD_SOURCE_MODE must be git or path (got: ${POD_SOURCE_MODE})"
            ;;
    esac
    if [[ ! -f "${FIXTURE_DIR}/main.m" ]]; then
        mark_fail "pure Objective-C fixture is missing: Producer/Tests/ObjectiveCConsumer/main.m"
        return
    fi
    if rg --files "${FIXTURE_DIR}" | rg -q '\.swift$'; then
        mark_fail "Objective-C consumer fixture contains Swift source"
    else
        echo "OK: fixture contains no Swift source."
    fi
    if ! grep -Fq '@import VolcengineTLSProducer;' \
        "${FIXTURE_DIR}/main.m"; then
        mark_fail "fixture does not import the public SDK module"
    else
        echo "OK: fixture imports the public SDK module."
    fi
    if rg -n '^#import[[:space:]]+[<"](TLSProducerBridge|CTLSProducerCore)|^#include[[:space:]]+[<"](TLSProducerBridge|CTLSProducerCore)|TLSProducerBridge\.h|CTLSProducerCore\.h' "${FIXTURE_DIR}/main.m" >/dev/null; then
        mark_fail "fixture references an internal Bridge/Core header or symbol"
    else
        echo "OK: fixture does not reference private Bridge/Core headers."
    fi
    if [[ -z "${POD_BIN}" ]]; then
        mark_blocked "CocoaPods executable was not found in PATH; set POD_BIN to an executable path"
    elif [[ ! -x "${POD_BIN}" ]]; then
        mark_blocked "CocoaPods executable is unavailable: ${POD_BIN}"
    fi
    if [[ -z "${XCODEBUILD_BIN}" ]]; then
        mark_blocked "xcodebuild was not found in PATH; set XCODEBUILD_BIN to an executable path"
    elif ! command -v "${XCODEBUILD_BIN}" >/dev/null 2>&1; then
        mark_blocked "xcodebuild is unavailable: ${XCODEBUILD_BIN}"
    fi
    if [[ -z "${RUBY_BIN}" ]]; then
        mark_blocked "Ruby executable was not found in PATH; set RUBY_BIN to an executable path"
    elif [[ ! -x "${RUBY_BIN}" ]]; then
        mark_blocked "Ruby executable for xcodeproj is unavailable: ${RUBY_BIN}"
    elif ! "${RUBY_BIN}" -e 'require "xcodeproj"' >/dev/null 2>&1; then
        mark_blocked "xcodeproj gem is unavailable to ${RUBY_BIN}"
    fi
}

prepare_pod_source_snapshot() {
    local snapshot_root="${task_root}/pod source with spaces"
    if ! mkdir -p "${snapshot_root}/Producer/scripts"; then
        mark_fail "could not create temporary CocoaPods source snapshot"
        return 1
    fi
    if [[ ! -f "${REPO_ROOT}/VolcengineTLSProducer.podspec" ||
        ! -f "${REPO_ROOT}/LICENSE" ||
        ! -d "${REPO_ROOT}/Producer/Sources" ||
        ! -f "${REPO_ROOT}/Producer/scripts/TLSProducerBridge.modulemap" ]]; then
        mark_fail "CocoaPods source snapshot inputs are incomplete"
        return 1
    fi
    if ! cp "${REPO_ROOT}/VolcengineTLSProducer.podspec" "${snapshot_root}/VolcengineTLSProducer.podspec" ||
       ! cp "${REPO_ROOT}/LICENSE" "${snapshot_root}/LICENSE" ||
       ! cp -R "${REPO_ROOT}/Producer/Sources" "${snapshot_root}/Producer/" ||
       ! cp "${REPO_ROOT}/Producer/scripts/TLSProducerBridge.modulemap" \
           "${snapshot_root}/Producer/scripts/TLSProducerBridge.modulemap"; then
        mark_fail "could not copy CocoaPods source snapshot inputs"
        return 1
    fi

    pod_source_root="${snapshot_root}"
    if [[ "${POD_SOURCE_MODE}" == "path" ]]; then
        echo "OK: prepared temporary CocoaPods path source snapshot at ${pod_source_root}."
        return 0
    fi
    if [[ -z "${GIT_BIN}" ]]; then
        mark_blocked "git executable was not found in PATH; CocoaPods Git source mode requires git"
        return 1
    elif [[ ! -x "${GIT_BIN}" ]]; then
        mark_blocked "git executable is unavailable: ${GIT_BIN}"
        return 1
    fi

    local commit
    if ! commit="$(
        cd "${snapshot_root}" &&
        export GIT_CONFIG_NOSYSTEM=1 &&
        "${GIT_BIN}" init --quiet &&
        "${GIT_BIN}" add -- VolcengineTLSProducer.podspec LICENSE Producer/Sources \
            Producer/scripts/TLSProducerBridge.modulemap &&
        "${GIT_BIN}" -c core.hooksPath=/dev/null \
            -c commit.gpgSign=false \
            -c user.name='Objective-C consumer verifier' \
            -c user.email='objective-c-consumer-verifier@invalid' \
            commit --quiet --no-verify -m 'Objective-C consumer verifier snapshot' &&
        "${GIT_BIN}" rev-parse --verify HEAD
    )"; then
        mark_fail "could not commit temporary CocoaPods Git source snapshot"
        return 1
    fi
    pod_source_commit="${commit}"
    echo "OK: prepared temporary CocoaPods Git source snapshot at ${pod_source_root} (${pod_source_commit})."
}

ruby_literal() {
    "${RUBY_BIN}" -e 'print ARGV.fetch(0).dump' -- "$1"
}

git_file_url() {
    "${RUBY_BIN}" -e \
        'require "uri"; print "file://"; print URI::DEFAULT_PARSER.escape(File.expand_path(ARGV.fetch(0)))' \
        -- "$1"
}

write_podfile() {
    local root="$1"
    local target="$2"
    local platform="$3"
    local linkage="$4"
    local platform_line
    if [[ "${platform}" == "ios" ]]; then
        platform_line="platform :ios, '13.0'"
    else
        platform_line="platform :osx, '10.15'"
    fi
    local source_line
    if [[ "${POD_SOURCE_MODE}" == "git" ]]; then
        local source_url source_literal commit_literal
        source_url="$(git_file_url "${pod_source_root}")"
        source_literal="$(ruby_literal "${source_url}")"
        commit_literal="$(ruby_literal "${pod_source_commit}")"
        source_line="  pod 'VolcengineTLSProducer', :git => ${source_literal}, :commit => ${commit_literal}"
    else
        local path_literal
        path_literal="$(ruby_literal "${pod_source_root}")"
        source_line="  pod 'VolcengineTLSProducer', :path => ${path_literal}"
    fi
    {
        printf '%s\n' "${platform_line}"
        printf '%s\n' "install! 'cocoapods', :disable_input_output_paths => true"
        printf '%s\n' "target '${target}' do"
        if [[ "${linkage}" == "static-framework" ]]; then
            printf '%s\n' "  use_frameworks! :linkage => :static"
        fi
        printf '%s\n' "${source_line}"
        printf '%s\n' 'end'
    } > "${root}/Podfile"
}

generate_project() {
    local root="$1"
    local target="$2"
    local platform="$3"
    local source_file="${root}/main.m"
    local project_file="${root}/${target}.xcodeproj"
    local plist_file="${root}/Info.plist"
    cp "${FIXTURE_DIR}/main.m" "${source_file}"

    if [[ "${platform}" == "ios" ]]; then
        {
            printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
            printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
            printf '%s\n' '<plist version="1.0"><dict>'
            printf '%s\n' '<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>'
            printf '%s\n' '<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>'
            printf '%s\n' '<key>CFBundleName</key><string>$(PRODUCT_NAME)</string>'
            printf '%s\n' '<key>CFBundlePackageType</key><string>APPL</string>'
            printf '%s\n' '<key>CFBundleVersion</key><string>1</string>'
            printf '%s\n' '<key>CFBundleShortVersionString</key><string>1.0</string>'
            printf '%s\n' '<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>'
            printf '%s\n' '<key>LSRequiresIPhoneOS</key><true/>'
            printf '%s\n' '<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>'
            printf '%s\n' '<key>UILaunchScreen</key><dict></dict>'
            printf '%s\n' '</dict></plist>'
        } > "${plist_file}"
    fi

    "${RUBY_BIN}" - "${project_file}" "${source_file}" "${target}" "${platform}" "${plist_file}" <<'RUBY'
require "xcodeproj"

project_path, source_path, target_name, platform, plist_path = ARGV
project = Xcodeproj::Project.new(project_path)
deployment = platform == "ios" ? "13.0" : "10.15"
# xcodeproj calls the macOS command-line product `:command_line_tool`;
# `:tool` is not a valid product key and leaves productTypeIdentifier nil
# in the generated PBXNativeTarget.
target_type = platform == "ios" ? :application : :command_line_tool
target_platform = platform == "ios" ? :ios : :osx
target = project.new_target(target_type, target_name, target_platform, deployment)
source_ref = project.main_group.new_file(source_path)
target.add_file_references([source_ref])

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["PRODUCT_NAME"] = target_name
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.volcengine.#{target_name.downcase}"
  settings["CLANG_ENABLE_MODULES"] = "YES"
  settings["CLANG_ENABLE_OBJC_ARC"] = "YES"
  settings["CODE_SIGNING_ALLOWED"] = "NO"
  settings["CODE_SIGNING_REQUIRED"] = "NO"
  settings["CODE_SIGN_IDENTITY"] = ""
  settings["ONLY_ACTIVE_ARCH"] = "YES"
  if platform == "ios"
    settings["IPHONEOS_DEPLOYMENT_TARGET"] = deployment
    settings["INFOPLIST_FILE"] = plist_path
    settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  else
    settings["MACOSX_DEPLOYMENT_TARGET"] = deployment
    settings["GENERATE_INFOPLIST_FILE"] = "YES"
  end
  settings["ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"] = "YES"
  settings["LD_RUNPATH_SEARCH_PATHS"] = if platform == "ios"
    "/usr/lib/swift $(inherited) @executable_path/Frameworks @loader_path/Frameworks"
  else
    "/usr/lib/swift $(inherited) @executable_path/../Frameworks @loader_path/../Frameworks"
  end
end

project.save
RUBY
}

show_failure_log() {
    local label="$1"
    local log="$2"
    echo "--- ${label} first diagnostics ---"
    grep -n -E 'error:|fatal error:|FAIL:|failed|Error Domain' "${log}" | head -30 || true
    tail -20 "${log}" || true
    echo "--- end diagnostics ---"
}

run_cocoapods_consumer() {
    local platform="$1"
    local linkage="$2"
    local run_binary="$3"
    local label="${platform}-${linkage}"
    local root="${task_root}/${label}/consumer with spaces"
    local target="TLSObjCConsumer${platform}${linkage//-/}"
    local pod_log="${root}/pod-install.log"
    local build_log="${root}/xcodebuild.log"
    local runtime_log="${root}/runtime.log"
    local build_root="${root}/DerivedData"
    local workspace="${root}/${target}.xcworkspace"
    local binary=""
    local cp_cache_dir="${task_root}/CP_CACHE_DIR/${label}"

    mkdir -p "${root}"
    write_podfile "${root}" "${target}" "${platform}" "${linkage}"
    generate_project "${root}" "${target}" "${platform}"
    ran=$((ran + 1))
    echo "== CocoaPods ${label} external Objective-C consumer =="

    if ! mkdir -p "${cp_cache_dir}"; then
        mark_fail "could not create isolated CocoaPods cache directory for ${label}"
        return
    fi
    if ! CP_CACHE_DIR="${cp_cache_dir}" COCOAPODS_DISABLE_STATS=1 \
        "${POD_BIN}" install --no-repo-update "--project-directory=${root}" \
        >"${pod_log}" 2>&1; then
        show_failure_log "CocoaPods ${label}" "${pod_log}"
        mark_fail "CocoaPods install failed for ${label}"
        return
    fi
    if [[ "${POD_SOURCE_MODE}" == "git" ]]; then
        local installed_modulemap="${root}/Pods/VolcengineTLSProducer/Producer/scripts/TLSProducerBridge.modulemap"
        if [[ ! -f "${installed_modulemap}" ]]; then
            mark_fail "CocoaPods Git install did not preserve ${installed_modulemap}"
            return
        fi
        echo "OK: CocoaPods Git install preserved the modulemap after checkout cleanup."
    fi
    if [[ ! -d "${workspace}" ]]; then
        mark_fail "CocoaPods did not create ${workspace}"
        return
    fi
    echo "OK: CocoaPods generated workspace for ${label}."

    if ! "${XCODEBUILD_BIN}" -workspace "${workspace}" -scheme "${target}" \
        -configuration Release -sdk "$([[ "${platform}" == "ios" ]] && echo iphonesimulator || echo macosx)" \
        -derivedDataPath "${build_root}" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
        build >"${build_log}" 2>&1; then
        show_failure_log "xcodebuild ${label}" "${build_log}"
        mark_fail "xcodebuild failed for ${label}"
        return
    fi
    echo "OK: xcodebuild built pure Objective-C CocoaPods consumer for ${label}."

    if [[ "${platform}" == "macos" && "${run_binary}" == "1" ]]; then
        binary="$(find "${build_root}/Build/Products/Release" -type f -name "${target}" \
            -perm -111 -print -quit 2>/dev/null || true)"
        if [[ -z "${binary}" || ! -x "${binary}" ]]; then
            mark_fail "macOS ${label} executable was not found"
            return
        fi
        if ! "${binary}" >"${runtime_log}" 2>&1; then
            show_failure_log "runtime ${label}" "${runtime_log}"
            mark_fail "macOS ${label} Objective-C consumer failed at runtime"
            return
        fi
        if ! grep -Fq 'Objective-C consumer PASS' "${runtime_log}"; then
            show_failure_log "runtime ${label}" "${runtime_log}"
            mark_fail "macOS ${label} did not report the consumer PASS marker"
            return
        fi
        echo "OK: macOS ${label} Objective-C consumer ran offline and validated the wire body."
    fi

    if [[ "${platform}" == "ios" && "${RUN_IOS_SIMULATOR:-0}" == "1" ]]; then
        if ! command -v "${XCRUN_BIN}" >/dev/null 2>&1; then
            echo "SKIP: xcrun unavailable; iOS Simulator runtime execution was not requested."
        else
            local device_id booted_devices booted_count
            booted_devices="$("${XCRUN_BIN}" simctl list devices booted 2>/dev/null |
                awk -F '[()]' '/Booted/{print $2}')"
            booted_count="$(printf '%s\n' "${booted_devices}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
            if [[ -n "${IOS_SIMULATOR_UDID:-}" ]]; then
                device_id="${IOS_SIMULATOR_UDID}"
                if ! printf '%s\n' "${booted_devices}" | grep -F -x -q "${device_id}"; then
                    mark_blocked "IOS_SIMULATOR_UDID is not booted: ${device_id}"
                    return
                fi
            elif [[ "${booted_count}" -eq 1 ]]; then
                device_id="${booted_devices}"
            elif [[ "${booted_count}" -gt 1 ]]; then
                echo "SKIP: multiple iOS Simulators are booted; set IOS_SIMULATOR_UDID to select one."
                return
            else
                device_id=""
            fi
            if [[ -z "${device_id}" ]]; then
                echo "SKIP: no booted iOS Simulator; compile verification for ${label} passed."
            else
                local app_path
                app_path="$(find "${build_root}/Build/Products/Release-iphonesimulator" \
                    -maxdepth 1 -type d -name "${target}.app" -print -quit 2>/dev/null || true)"
                if [[ -z "${app_path}" ]] || ! "${XCRUN_BIN}" simctl install "${device_id}" "${app_path}" \
                    >"${runtime_log}" 2>&1; then
                    show_failure_log "simctl install ${label}" "${runtime_log}"
                    mark_fail "iOS Simulator install failed for ${label}"
                    return
                fi
                bundle_id="com.volcengine.$(printf '%s' "${target}" | tr '[:upper:]' '[:lower:]')"
                local launch_pid launch_rc marker_seen=0
                "${XCRUN_BIN}" simctl launch --console "${device_id}" "${bundle_id}" \
                    >"${runtime_log}" 2>&1 &
                launch_pid=$!
                # UIKit keeps the app alive after completion. Stop observing
                # once its final marker is flushed, then terminate our app.
                local attempt
                for ((attempt=0; attempt<240; attempt++)); do
                    if grep -Fq 'Objective-C consumer PASS' "${runtime_log}"; then
                        marker_seen=1
                        break
                    fi
                    if ! kill -0 "${launch_pid}" 2>/dev/null; then
                        break
                    fi
                    sleep 0.25
                done
                if kill -0 "${launch_pid}" 2>/dev/null; then
                    kill "${launch_pid}" 2>/dev/null || true
                    "${XCRUN_BIN}" simctl terminate "${device_id}" "${bundle_id}" >/dev/null 2>&1 || true
                fi
                wait "${launch_pid}" 2>/dev/null || launch_rc=$?
                launch_rc="${launch_rc:-0}"
                if [[ "${marker_seen}" -ne 1 ]]; then
                    show_failure_log "simctl launch ${label}" "${runtime_log}"
                    mark_fail "iOS Simulator did not report Objective-C consumer PASS before deadline"
                    return
                fi
                if grep -q 'is implemented in both' "${runtime_log}"; then
                    mark_fail "iOS Simulator loaded duplicate runtime classes"
                    return
                fi
                if [[ "${launch_rc}" -ne 0 && "${launch_rc}" -ne 143 ]]; then
                    show_failure_log "simctl launch ${label}" "${runtime_log}"
                    mark_fail "iOS Simulator consumer exited with status ${launch_rc}"
                    return
                fi
                echo "OK: iOS Simulator built and ran ${label} with the PASS marker."
            fi
        fi
    fi
}

probe_swiftpm() {
    echo "== SwiftPM pure Objective-C target probe =="
    if [[ "${SKIP_SWIFTPM:-0}" == "1" ]]; then
        echo "SKIP: SwiftPM probe disabled by SKIP_SWIFTPM=1."
        return
    fi
    if ! command -v swift >/dev/null 2>&1; then
        mark_blocked "swift unavailable; SwiftPM Objective-C consumer cannot be verified."
        return
    fi

    local probe_root="${task_root}/swiftpm-objc-probe"
    local probe_log="${probe_root}/swift-build.log"
    mkdir -p "${probe_root}/Sources/ObjectiveCProbe"
    {
        printf '%s\n' '// swift-tools-version: 5.8'
        printf '%s\n' 'import PackageDescription'
        printf '%s\n' 'let package = Package('
        printf '%s\n' '    name: "ObjectiveCProbe",'
        printf '%s\n' '    platforms: [.macOS(.v10_15)],'
        printf '%s\n' '    dependencies: [.package(name: "TLSUnderTest", path: "'"${REPO_ROOT}"'")],'
        printf '%s\n' '    targets: ['
        printf '%s\n' '        .executableTarget('
        printf '%s\n' '            name: "ObjectiveCProbe",'
        printf '%s\n' '            dependencies: [.product(name: "VolcengineTLSProducer", package: "TLSUnderTest")],'
        printf '%s\n' '            path: "Sources/ObjectiveCProbe",'
        printf '%s\n' '            cSettings: [.unsafeFlags(["-fmodules", "-fobjc-arc"])]'
        printf '%s\n' '        )'
        printf '%s\n' '    ]'
        printf '%s\n' ')'
    } > "${probe_root}/Package.swift"
    cp "${FIXTURE_DIR}/main.m" "${probe_root}/Sources/ObjectiveCProbe/main.m"

    # SwiftPM package manifests may use a host-specific module cache. Keep the
    # probe isolated and make its expected import error inspectable.
    local cache
    cache="$(mktemp -d "${probe_root}/module-cache.XXXXXX")"
    if CLANG_MODULE_CACHE_PATH="${cache}" swift build --disable-sandbox \
        --package-path "${probe_root}" --scratch-path "${probe_root}/.build" \
        >"${probe_log}" 2>&1; then
        local probe_binary
        probe_binary="$(find "${probe_root}/.build" -type f -name ObjectiveCProbe -perm -111 \
            -print -quit 2>/dev/null || true)"
        if [[ -z "${probe_binary}" || ! -x "${probe_binary}" ]]; then
            mark_fail "SwiftPM pure Objective-C probe built but executable was not found"
            return
        fi
        if ! "${probe_binary}" >>"${probe_log}" 2>&1; then
            mark_fail "SwiftPM pure Objective-C probe linked but failed at runtime"
            return
        fi
        if ! grep -Fq 'Objective-C consumer PASS' "${probe_log}"; then
            mark_fail "SwiftPM Objective-C consumer did not report its completion marker"
            return
        fi
        echo "OK: SwiftPM pure Objective-C target imported the generated header, linked, and ran."
        return
    fi
    mark_fail "SwiftPM pure Objective-C consumer failed"
    show_failure_log "SwiftPM pure Objective-C probe" "${probe_log}"
}

preflight
if [[ "${overall}" -eq 0 ]]; then
    task_root="$(mktemp -d "${TMPDIR:-/tmp}/tls-objc-consumer.XXXXXX")"
    if [[ "${KEEP_SUCCESS:-0}" == "1" ]]; then
        keep_temp=1
    fi
    pod_source_ready=1
    if [[ "${SKIP_MACOS:-0}" != "1" || "${SKIP_IOS:-0}" != "1" ]]; then
        if ! prepare_pod_source_snapshot; then
            pod_source_ready=0
        fi
    fi
    probe_swiftpm
    if [[ "${pod_source_ready}" -eq 1 ]]; then
        if [[ "${SKIP_MACOS:-0}" != "1" ]]; then
            run_cocoapods_consumer macos static-library 1
            run_cocoapods_consumer macos static-framework 1
        else
            echo "SKIP: macOS checks disabled by SKIP_MACOS=1."
        fi
        if [[ "${SKIP_IOS:-0}" != "1" ]]; then
            run_cocoapods_consumer ios static-library 0
            run_cocoapods_consumer ios static-framework 0
        else
            echo "SKIP: iOS Simulator checks disabled by SKIP_IOS=1."
        fi
    else
        echo "SKIP: CocoaPods checks were not started because the source snapshot failed."
    fi
fi

echo ""
if [[ "${overall}" -eq 0 && "${ran}" -eq 0 && "${blocked}" -eq 0 ]]; then
    echo "SKIP: no Objective-C consumer checks ran."
elif [[ "${overall}" -eq 0 ]]; then
    echo "OK: Objective-C consumer verification completed (${ran} CocoaPods builds; optional skips listed above)."
else
    echo "FAIL: Objective-C consumer verification is incomplete or one or more checks failed."
fi
exit "${overall}"
