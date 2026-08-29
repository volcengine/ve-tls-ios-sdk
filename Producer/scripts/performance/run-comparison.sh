#!/bin/bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
package_root=$(cd -- "$script_dir/../../.." && pwd)
harness_source="$package_root/Producer/Examples/PerformanceHarness"
sls_root=${TLS_PERF_SLS_ROOT:-"$package_root/../aliyun-log-ios-sdk"}
output_root=${TLS_PERF_OUTPUT_DIR:-"$package_root/.build/performance-reports/$(date +%Y%m%d-%H%M%S)"}
warmup_seconds=${TLS_PERF_WARMUP_SECONDS:-10}
measure_seconds=${TLS_PERF_MEASURE_SECONDS:-30}
settle_timeout_seconds=${TLS_PERF_SETTLE_TIMEOUT_SECONDS:-60}
repeats=${TLS_PERF_REPEATS:-3}
rates=${TLS_PERF_RATES:-"100 300"}
modes=${TLS_PERF_MODES:-"memory persistent"}
sdks=${TLS_PERF_SDKS:-"tls sls"}
enforce_gate=${TLS_PERF_ENFORCE_GATE:-0}
require_clean=${TLS_PERF_REQUIRE_CLEAN:-0}
bundle_id=com.volcengine.tls.PerformanceHarness

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -d "$harness_source" ]] || die "performance harness not found"
[[ -d "$sls_root/.git" ]] || die "SLS repository not found: $sls_root"
[[ "$repeats" =~ ^[1-9][0-9]*$ ]] || die "TLS_PERF_REPEATS must be a positive integer"
[[ "$enforce_gate" == 0 || "$enforce_gate" == 1 ]] || die "TLS_PERF_ENFORCE_GATE must be 0 or 1"
[[ "$require_clean" == 0 || "$require_clean" == 1 ]] || die "TLS_PERF_REQUIRE_CLEAN must be 0 or 1"

for sdk in $sdks; do
    [[ "$sdk" == tls || "$sdk" == sls ]] || die "unsupported SDK: $sdk"
done
sdk_words=$(printf '%s\n' $sdks | sort | tr '\n' ' ')
[[ "$sdk_words" == "sls tls " ]] || die "TLS_PERF_SDKS must contain exactly: tls sls"
for mode in $modes; do
    [[ "$mode" == memory || "$mode" == persistent ]] || die "unsupported mode: $mode"
done
for rate in $rates; do
    [[ "$rate" =~ ^[1-9][0-9]*$ ]] || die "invalid rate: $rate"
done

sls_tag=$(git -C "$sls_root" describe --tags --exact-match 2>/dev/null || true)
[[ "$sls_tag" == 4.3.4 ]] || die "SLS baseline must be exact tag 4.3.4 (found: ${sls_tag:-none})"
[[ -z "$(git -C "$sls_root" status --porcelain)" ]] || die "SLS 4.3.4 worktree must be clean"
if [[ "$require_clean" == 1 && -n "$(git -C "$package_root" status --porcelain)" ]]; then
    die "TLS_PERF_REQUIRE_CLEAN=1 but TLS worktree is dirty"
fi
if [[ -d "$output_root" && -n "$(find "$output_root" -mindepth 1 -print -quit)" ]]; then
    die "TLS_PERF_OUTPUT_DIR must be empty to prevent stale-run contamination"
fi

pod_bin=${POD_BIN:-$(command -v pod || true)}
if [[ -z "$pod_bin" && -x /opt/homebrew/lib/ruby/gems/3.3.0/bin/pod ]]; then
    pod_bin=/opt/homebrew/lib/ruby/gems/3.3.0/bin/pod
fi
[[ -x "$pod_bin" ]] || die "CocoaPods executable not found"
ruby_bin=${RUBY_BIN:-/opt/homebrew/opt/ruby@3.3/bin/ruby}
[[ -x "$ruby_bin" ]] || ruby_bin=$(command -v ruby || true)
[[ -x "$ruby_bin" ]] || die "Ruby executable not found"
"$ruby_bin" -rxcodeproj -e 'abort unless Gem::Version.new(Xcodeproj::VERSION) >= Gem::Version.new("1.20")' \
    || die "Ruby xcodeproj gem is unavailable"

device=${TLS_PERF_SIMULATOR_ID:-}
if [[ -z "$device" ]]; then
    device=$(xcrun simctl list devices -j | python3 -c '
import json,sys
data=json.load(sys.stdin)
for runtime in data.get("devices", {}).values():
    for item in runtime:
        if item.get("state") == "Booted" and item.get("isAvailable", True):
            print(item["udid"]); raise SystemExit(0)
raise SystemExit(1)
' || true)
fi
[[ "$device" =~ ^[0-9A-Fa-f-]{36}$ ]] || die "set TLS_PERF_SIMULATOR_ID to one exact simulator UUID"
device_line=$(xcrun simctl list devices | awk -v wanted="$device" 'index($0, "(" wanted ")") { print }')
[[ "$device_line" == *"(Booted)"* ]] || die "simulator must already be Booted: $device"

mkdir -p "$output_root/runs"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/tls-performance-fixture.XXXXXX")
server_pid=
sampler_pid=
app_pid=

cleanup() {
    if [[ -n "$sampler_pid" ]] && kill -0 "$sampler_pid" 2>/dev/null; then
        kill "$sampler_pid" 2>/dev/null || true
        wait "$sampler_pid" 2>/dev/null || true
    fi
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
    fi
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$fixture_root"
}
trap cleanup EXIT INT TERM

cp -R "$harness_source/." "$fixture_root/"
(
    cd "$fixture_root"
    "$ruby_bin" generate-project.rb
    TLS_SDK_ROOT="$package_root" SLS_SDK_ROOT="$sls_root" \
        "$pod_bin" install --no-repo-update
) >"$output_root/pod-install.log" 2>&1

derived_data="$fixture_root/DerivedData"
xcodebuild \
    -workspace "$fixture_root/PerformanceHarness.xcworkspace" \
    -scheme PerformanceHarness \
    -configuration Release \
    -destination "platform=iOS Simulator,id=$device" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=YES \
    EXCLUDED_ARCHS= \
    build >"$output_root/xcodebuild.log" 2>&1

app_path="$derived_data/Build/Products/Release-iphonesimulator/PerformanceHarness.app"
[[ -d "$app_path" ]] || die "built app not found: $app_path"

cert_dir="$fixture_root/certificates"
"$package_root/Producer/scripts/test-support/make-test-ca.sh" "$cert_dir" \
    >"$output_root/certificate-paths.txt"
"$package_root/Producer/scripts/test-support/install-test-ca-on-simulator.sh" \
    "$device" "$cert_dir/ca.cert.pem" >"$output_root/ca-install.log" 2>&1

ready_file="$fixture_root/server-ready.json"
python3 -u "$fixture_root/mock_https_server.py" \
    --cert "$cert_dir/server.cert.pem" \
    --key "$cert_dir/server.key.pem" \
    --ready-file "$ready_file" \
    --delay-milliseconds 5 \
    >"$output_root/server.log" 2>&1 &
server_pid=$!
printf '%s\n' "$server_pid" >"$output_root/server-pid.txt"
for _ in $(seq 1 100); do
    [[ -s "$ready_file" ]] && break
    kill -0 "$server_pid" 2>/dev/null || die "HTTPS fixture exited before readiness"
    sleep 0.1
done
[[ -s "$ready_file" ]] || die "HTTPS fixture did not become ready"
port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$ready_file")
endpoint="https://127.0.0.1:$port"

git -C "$package_root" rev-parse HEAD >"$output_root/tls-head.txt"
git -C "$package_root" status --porcelain=v1 >"$output_root/tls-status.txt"
git -C "$sls_root" rev-parse HEAD >"$output_root/sls-head.txt"
git -C "$sls_root" status --porcelain=v1 >"$output_root/sls-status.txt"
printf '%s\n' "$sls_tag" >"$output_root/sls-tag.txt"
xcodebuild -version >"$output_root/xcode-version.txt"
xcrun simctl list devices | awk -v wanted="$device" 'index($0, "(" wanted ")") { print }' \
    >"$output_root/simulator.txt"

epoch_milliseconds() {
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

run_case() {
    local sdk=$1
    local mode=$2
    local rate=$3
    local repetition=$4
    local run_id="${sdk}-${mode}-${rate}-r${repetition}"
    local run_dir="$output_root/runs/$run_id"
    mkdir -p "$run_dir"

    curl --silent --show-error --fail --cacert "$cert_dir/ca.cert.pem" \
        "$endpoint/__reset" -o /dev/null
    xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$device" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl install "$device" "$app_path"

    local launch_output
    launch_output=$(
        SIMCTL_CHILD_TLS_PERF_SDK="$sdk" \
        SIMCTL_CHILD_TLS_PERF_MODE="$mode" \
        SIMCTL_CHILD_TLS_PERF_ENDPOINT="$endpoint" \
        SIMCTL_CHILD_TLS_PERF_RATE="$rate" \
        SIMCTL_CHILD_TLS_PERF_WARMUP_SECONDS="$warmup_seconds" \
        SIMCTL_CHILD_TLS_PERF_MEASURE_SECONDS="$measure_seconds" \
        SIMCTL_CHILD_TLS_PERF_SETTLE_TIMEOUT_SECONDS="$settle_timeout_seconds" \
        SIMCTL_CHILD_TLS_PERF_RUN_ID="$run_id" \
        xcrun simctl launch --terminate-running-process "$device" "$bundle_id"
    )
    app_pid=$(printf '%s\n' "$launch_output" | awk '{print $NF}')
    [[ "$app_pid" =~ ^[0-9]+$ ]] || die "$run_id did not return a numeric app PID"
    printf '%s\n' "$app_pid" >"$run_dir/app-pid.txt"

    (
        printf 'epoch_ms\tcpu_percent\trss_kb\n'
        while kill -0 "$app_pid" 2>/dev/null; do
            local_epoch=$(epoch_milliseconds)
            process_values=$(ps -p "$app_pid" -o %cpu= -o rss= | awk 'NF >= 2 { print $1 "\t" $2 }')
            if [[ -n "$process_values" ]]; then
                printf '%s\t%s\n' "$local_epoch" "$process_values"
            fi
            sleep 1
        done
    ) >"$run_dir/process-samples.tsv" &
    sampler_pid=$!

    local data_container
    data_container=$(xcrun simctl get_app_container "$device" "$bundle_id" data)
    local result_path="$data_container/Documents/performance-result.json"
    local timeout_seconds
    timeout_seconds=$(python3 -c 'import math,sys; print(math.ceil(sum(map(float,sys.argv[1:]))+60))' \
        "$warmup_seconds" "$measure_seconds" "$settle_timeout_seconds")
    local deadline=$(( $(date +%s) + timeout_seconds ))
    while [[ ! -s "$result_path" && $(date +%s) -lt $deadline ]]; do
        kill -0 "$app_pid" 2>/dev/null || die "$run_id app exited before writing evidence"
        sleep 0.2
    done
    [[ -s "$result_path" ]] || die "$run_id timed out waiting for app evidence"
    cp "$result_path" "$run_dir/app-result.json"
    curl --silent --show-error --fail --cacert "$cert_dir/ca.cert.pem" \
        "$endpoint/__stats" -o "$run_dir/server-stats.json"

    xcrun simctl terminate "$device" "$bundle_id"
    local stop_deadline=$(( $(date +%s) + 10 ))
    while kill -0 "$app_pid" 2>/dev/null && [[ $(date +%s) -lt $stop_deadline ]]; do
        sleep 0.1
    done
    if kill -0 "$app_pid" 2>/dev/null; then
        die "$run_id app process remains after simctl terminate"
    fi
    wait "$sampler_pid" 2>/dev/null || true
    sampler_pid=
    printf 'terminated\n' >"$run_dir/process-cleanup.txt"
    app_pid=
    xcrun simctl uninstall "$device" "$bundle_id"
}

for mode in $modes; do
    for rate in $rates; do
        for repetition in $(seq 1 "$repeats"); do
            if (( repetition % 2 == 1 )); then
                ordered_sdks=$sdks
            else
                ordered_sdks=$(printf '%s\n' $sdks | awk '{ values[NR]=$0 } END { for (i=NR; i>=1; i--) printf "%s%s", values[i], (i==1 ? "" : " ") }')
            fi
            for sdk in $ordered_sdks; do
                echo "RUN: sdk=$sdk mode=$mode rate=$rate repetition=$repetition"
                run_case "$sdk" "$mode" "$rate" "$repetition"
            done
        done
    done
done

git -C "$package_root" rev-parse HEAD >"$output_root/tls-head-end.txt"
git -C "$package_root" status --porcelain=v1 >"$output_root/tls-status-end.txt"
git -C "$sls_root" rev-parse HEAD >"$output_root/sls-head-end.txt"
git -C "$sls_root" status --porcelain=v1 >"$output_root/sls-status-end.txt"
cmp -s "$output_root/tls-head.txt" "$output_root/tls-head-end.txt" \
    || die "TLS HEAD changed during the benchmark"
cmp -s "$output_root/tls-status.txt" "$output_root/tls-status-end.txt" \
    || die "TLS worktree status changed during the benchmark"
cmp -s "$output_root/sls-head.txt" "$output_root/sls-head-end.txt" \
    || die "SLS HEAD changed during the benchmark"
cmp -s "$output_root/sls-status.txt" "$output_root/sls-status-end.txt" \
    || die "SLS worktree status changed during the benchmark"

kill "$server_pid"
wait "$server_pid"
if kill -0 "$server_pid" 2>/dev/null; then
    die "HTTPS fixture process remains after shutdown"
fi
server_pid=
printf 'terminated\n' >"$output_root/server-cleanup.txt"

analyzer_arguments=(
    --input-dir "$output_root/runs"
    --output-json "$output_root/summary.json"
    --output-markdown "$output_root/summary.md"
)
if [[ "$enforce_gate" == 1 ]]; then
    analyzer_arguments+=(--enforce-gate)
fi
python3 "$fixture_root/analyze_results.py" "${analyzer_arguments[@]}"

(cd "$output_root" && shasum -a 256 \
    tls-head.txt tls-status.txt tls-head-end.txt tls-status-end.txt \
    sls-head.txt sls-status.txt sls-head-end.txt sls-status-end.txt sls-tag.txt \
    xcode-version.txt simulator.txt \
    pod-install.log xcodebuild.log certificate-paths.txt ca-install.log server.log \
    server-pid.txt server-cleanup.txt summary.json summary.md \
    runs/*/app-result.json runs/*/server-stats.json runs/*/process-samples.tsv \
    runs/*/app-pid.txt runs/*/process-cleanup.txt >SHA256SUMS)

echo "PASS: performance comparison evidence validated"
echo "OUTPUT_DIR=$output_root"
