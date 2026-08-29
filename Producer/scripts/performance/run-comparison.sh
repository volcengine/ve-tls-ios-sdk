#!/bin/bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
package_root=$(cd -- "$script_dir/../../.." && pwd)
harness_source="$package_root/Producer/Examples/PerformanceHarness"
sls_root=${TLS_PERF_SLS_ROOT:-"$package_root/../aliyun-log-ios-sdk"}
prepared_fixture_root=${TLS_PERF_PREPARED_FIXTURE_ROOT:-}
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
require_idle_host=${TLS_PERF_REQUIRE_IDLE_HOST:-1}
nsurlsessiond_max_bytes_per_second=${TLS_PERF_NSURLSESSIOND_MAX_BYTES_PER_SECOND:-262144}
host_cpu_idle_samples=${TLS_PERF_HOST_CPU_IDLE_SAMPLES:-5}
host_cpu_min_idle_percent=${TLS_PERF_HOST_CPU_MIN_IDLE_PERCENT:-65}
host_cpu_mean_idle_percent=${TLS_PERF_HOST_CPU_MEAN_IDLE_PERCENT:-75}
host_disk_samples=${TLS_PERF_HOST_DISK_SAMPLES:-4}
host_disk_max_megabytes_per_second=${TLS_PERF_HOST_DISK_MAX_MEGABYTES_PER_SECOND:-5}
host_resource_settle_seconds=${TLS_PERF_HOST_RESOURCE_SETTLE_SECONDS:-10}
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
[[ "$require_idle_host" == 0 || "$require_idle_host" == 1 ]] || die "TLS_PERF_REQUIRE_IDLE_HOST must be 0 or 1"
[[ "$nsurlsessiond_max_bytes_per_second" =~ ^[0-9]+$ ]] \
    || die "TLS_PERF_NSURLSESSIOND_MAX_BYTES_PER_SECOND must be a non-negative integer"
[[ "$host_cpu_idle_samples" =~ ^[1-9][0-9]*$ ]] \
    || die "TLS_PERF_HOST_CPU_IDLE_SAMPLES must be a positive integer"
[[ "$host_disk_samples" =~ ^[1-9][0-9]*$ ]] \
    || die "TLS_PERF_HOST_DISK_SAMPLES must be a positive integer"
[[ "$host_resource_settle_seconds" =~ ^[0-9]+$ ]] \
    || die "TLS_PERF_HOST_RESOURCE_SETTLE_SECONDS must be a non-negative integer"
for percent in "$host_cpu_min_idle_percent" "$host_cpu_mean_idle_percent"; do
    [[ "$percent" =~ ^([0-9]+)(\.[0-9]+)?$ ]] \
        || die "host CPU idle thresholds must be decimal percentages"
    awk -v value="$percent" 'BEGIN { exit !(value >= 0 && value <= 100) }' \
        || die "host CPU idle thresholds must be within 0...100"
done
[[ "$host_disk_max_megabytes_per_second" =~ ^([0-9]+)(\.[0-9]+)?$ ]] \
    || die "TLS_PERF_HOST_DISK_MAX_MEGABYTES_PER_SECOND must be a non-negative decimal"

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

pod_bin=
ruby_bin=
if [[ -n "$prepared_fixture_root" ]]; then
    [[ -d "$prepared_fixture_root/PerformanceHarness.xcworkspace" ]] \
        || die "prepared performance fixture is incomplete: $prepared_fixture_root"
    [[ -d "$prepared_fixture_root/Pods/Pods.xcodeproj" ]] \
        || die "prepared performance fixture has no Pods project: $prepared_fixture_root"
else
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
fi

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
server_pid=
sampler_pid=
app_pid=

capture_host_state() {
    local destination=$1
    {
        date -u '+utc=%Y-%m-%dT%H:%M:%SZ'
        uptime
        printf 'vm.loadavg='
        sysctl -n vm.loadavg
        pmset -g therm
        printf '%s\n' 'top_cpu_processes:'
        ps -Ao pid=,%cpu=,rss=,comm= -r | sed -n '1,20p'
    } >"$destination"
}

assert_idle_host() {
    local phase=$1
    local evidence="$output_root/host-idle-$phase.txt"
    local active_downloads
    local active_runtime_postprocessing
    local nsurlsessiond_bytes_per_second
    if [[ "$require_idle_host" != 1 ]]; then
        printf 'phase=%s\nidle_host_check=disabled\n' "$phase" >"$evidence"
        return 0
    fi

    active_downloads=$(pgrep -fl '[x]codebuild.*-downloadPlatform' || true)
    active_runtime_postprocessing=$(
        pgrep -fl '[u]pdate_dyld_sim_shared_cache' || true
    )
    nsurlsessiond_bytes_per_second=$(
        /usr/bin/nettop -P -L 2 -d -J bytes_in,bytes_out -p nsurlsessiond 2>/dev/null \
            | awk -F, '
                /^,bytes_in,bytes_out,/ { sample++; next }
                sample >= 2 && /^nsurlsessiond\./ {
                    bytes_in = $2 == "" ? 0 : $2
                    bytes_out = $3 == "" ? 0 : $3
                    total += bytes_in + bytes_out
                }
                END { printf "%.0f\n", total + 0 }
            '
    )
    {
        printf 'phase=%s\n' "$phase"
        printf 'active_platform_downloads=%s\n' "${active_downloads:-none}"
        printf 'active_runtime_postprocessing=%s\n' "${active_runtime_postprocessing:-none}"
        printf 'nsurlsessiond_bytes_per_second=%s\n' "$nsurlsessiond_bytes_per_second"
        printf 'nsurlsessiond_limit_bytes_per_second=%s\n' "$nsurlsessiond_max_bytes_per_second"
    } >"$evidence"
    if [[ -n "$active_downloads" ]]; then
        die "$phase host check found an active Xcode platform download: $active_downloads"
    fi
    if [[ -n "$active_runtime_postprocessing" ]]; then
        die "$phase host check found active Simulator Runtime post-processing: $active_runtime_postprocessing"
    fi
    if (( nsurlsessiond_bytes_per_second > nsurlsessiond_max_bytes_per_second )); then
        die "$phase host check found active nsurlsessiond traffic: ${nsurlsessiond_bytes_per_second} B/s (limit ${nsurlsessiond_max_bytes_per_second} B/s)"
    fi
}

assert_quiet_host_resources() {
    local phase=$1
    local evidence="$output_root/host-resources-$phase.txt"
    local cpu_raw="$output_root/.host-cpu-$phase.raw.txt"
    local disk_raw="$output_root/.host-disk-$phase.raw.txt"
    local cpu_values
    local cpu_count
    local cpu_min
    local cpu_mean
    local disk_values
    local disk_count
    local disk_max
    local disk_total_samples=$((host_disk_samples + 1))
    if [[ "$require_idle_host" != 1 ]]; then
        printf 'phase=%s\nquiet_host_resource_check=disabled\n' "$phase" >"$evidence"
        return 0
    fi

    /usr/bin/top -l "$host_cpu_idle_samples" -s 1 -n 0 >"$cpu_raw"
    /usr/sbin/iostat -d -w 1 -c "$disk_total_samples" >"$disk_raw"
    cpu_values=$(
        awk '
            /^CPU usage:/ {
                for (i = 1; i <= NF; i++) {
                    if ($i == "idle") {
                        value = $(i - 1)
                        gsub(/%/, "", value)
                        print value
                    }
                }
            }
        ' "$cpu_raw"
    )
    cpu_count=$(printf '%s\n' "$cpu_values" | awk 'NF { count++ } END { print count + 0 }')
    [[ "$cpu_count" == "$host_cpu_idle_samples" ]] \
        || die "$phase host CPU check parsed $cpu_count/$host_cpu_idle_samples samples"
    cpu_min=$(printf '%s\n' "$cpu_values" | sort -n | sed -n '1p')
    cpu_mean=$(printf '%s\n' "$cpu_values" | awk 'NF { sum += $1; count++ } END { printf "%.2f", sum / count }')

    disk_values=$(
        awk '
            /^[[:space:]]*[0-9]/ {
                row++
                if (row == 1) next
                total = 0
                for (i = 3; i <= NF; i += 3) total += $i
                printf "%.2f\n", total
            }
        ' "$disk_raw"
    )
    disk_count=$(printf '%s\n' "$disk_values" | awk 'NF { count++ } END { print count + 0 }')
    [[ "$disk_count" == "$host_disk_samples" ]] \
        || die "$phase host disk check parsed $disk_count/$host_disk_samples samples"
    disk_max=$(printf '%s\n' "$disk_values" | sort -n | tail -n 1)

    {
        printf 'phase=%s\n' "$phase"
        printf 'cpu_idle_samples=%s\n' "$cpu_count"
        printf 'cpu_idle_values_percent=%s\n' "$(printf '%s' "$cpu_values" | tr '\n' ',')"
        printf 'cpu_idle_min_percent=%s\n' "$cpu_min"
        printf 'cpu_idle_min_required_percent=%s\n' "$host_cpu_min_idle_percent"
        printf 'cpu_idle_mean_percent=%s\n' "$cpu_mean"
        printf 'cpu_idle_mean_required_percent=%s\n' "$host_cpu_mean_idle_percent"
        printf 'disk_samples=%s\n' "$disk_count"
        printf 'disk_total_values_megabytes_per_second=%s\n' "$(printf '%s' "$disk_values" | tr '\n' ',')"
        printf 'disk_max_megabytes_per_second=%s\n' "$disk_max"
        printf 'disk_max_allowed_megabytes_per_second=%s\n' "$host_disk_max_megabytes_per_second"
        printf '%s\n' 'top_raw_begin'
        sed -n '/^CPU usage:/p' "$cpu_raw"
        printf '%s\n' 'top_raw_end'
        printf '%s\n' 'iostat_raw_begin'
        sed -n '1,120p' "$disk_raw"
        printf '%s\n' 'iostat_raw_end'
    } >"$evidence"
    rm -f "$cpu_raw" "$disk_raw"

    awk -v actual="$cpu_min" -v required="$host_cpu_min_idle_percent" \
        'BEGIN { exit !(actual >= required) }' \
        || die "$phase host CPU idle minimum ${cpu_min}% is below ${host_cpu_min_idle_percent}%"
    awk -v actual="$cpu_mean" -v required="$host_cpu_mean_idle_percent" \
        'BEGIN { exit !(actual >= required) }' \
        || die "$phase host CPU idle mean ${cpu_mean}% is below ${host_cpu_mean_idle_percent}%"
    awk -v actual="$disk_max" -v allowed="$host_disk_max_megabytes_per_second" \
        'BEGIN { exit !(actual <= allowed) }' \
        || die "$phase host disk traffic ${disk_max} MB/s exceeds ${host_disk_max_megabytes_per_second} MB/s"
}

capture_host_state "$output_root/host-preflight.txt"
assert_idle_host preflight
assert_quiet_host_resources preflight

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/tls-performance-fixture.XXXXXX")
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

if [[ -n "$prepared_fixture_root" ]]; then
    cp -R "$prepared_fixture_root/." "$fixture_root/"
    if /usr/bin/grep -r -E \
        '\$\{PODS_ROOT\}.*__(TLS|SLS)_SDK_ROOT__' \
        "$fixture_root" >/dev/null 2>&1; then
        die "prepared performance fixture contains a non-canonical SDK path token"
    fi
    tls_pods_relative_path=$(python3 -c \
        'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' \
        "$package_root" "$fixture_root/Pods")
    sls_pods_relative_path=$(python3 -c \
        'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' \
        "$sls_root" "$fixture_root/Pods")
    tls_support_relative_path=$(python3 -c \
        'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' \
        "$fixture_root/Pods/Target Support Files/VolcengineTLSProducer" \
        "$package_root")
    sls_support_relative_path=$(python3 -c \
        'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' \
        "$fixture_root/Pods/Target Support Files/AliyunLogProducer" \
        "$sls_root")
    find "$fixture_root/Pods/Target Support Files" -type f -name '*.xcconfig' \
        -exec env \
            TLS_PODS_RELATIVE_PATH="$tls_pods_relative_path" \
            SLS_PODS_RELATIVE_PATH="$sls_pods_relative_path" \
            perl -pi -e '
                s#PODS_TARGET_SRCROOT = __TLS_SDK_ROOT__#PODS_TARGET_SRCROOT = \${PODS_ROOT}/$ENV{TLS_PODS_RELATIVE_PATH}#g;
                s#PODS_TARGET_SRCROOT = __SLS_SDK_ROOT__#PODS_TARGET_SRCROOT = \${PODS_ROOT}/$ENV{SLS_PODS_RELATIVE_PATH}#g;
            ' {} +
    TLS_SUPPORT_RELATIVE_PATH="$tls_support_relative_path" \
    SLS_SUPPORT_RELATIVE_PATH="$sls_support_relative_path" \
        perl -pi -e '
            s#__TLS_SUPPORT_FILES_RELATIVE__#$ENV{TLS_SUPPORT_RELATIVE_PATH}#g;
            s#__SLS_SUPPORT_FILES_RELATIVE__#$ENV{SLS_SUPPORT_RELATIVE_PATH}#g;
        ' "$fixture_root/Pods/Pods.xcodeproj/project.pbxproj"
    prepared_path_files=$(
        /usr/bin/grep -rl \
            -e '__TLS_SDK_ROOT__' \
            -e '__SLS_SDK_ROOT__' \
            "$fixture_root" || true
    )
    [[ -n "$prepared_path_files" ]] \
        || die "prepared performance fixture has no relocatable SDK path tokens"
    while IFS= read -r prepared_path_file; do
        TLS_SDK_ROOT_VALUE="$package_root" \
        SLS_SDK_ROOT_VALUE="$sls_root" \
            perl -pi -e '
                s/__TLS_SDK_ROOT__/$ENV{TLS_SDK_ROOT_VALUE}/g;
                s/__SLS_SDK_ROOT__/$ENV{SLS_SDK_ROOT_VALUE}/g;
            ' "$prepared_path_file"
    done <<<"$prepared_path_files"
    if /usr/bin/grep -r \
        -e '__TLS_SDK_ROOT__' \
        -e '__SLS_SDK_ROOT__' \
        -e '__TLS_SUPPORT_FILES_RELATIVE__' \
        -e '__SLS_SUPPORT_FILES_RELATIVE__' \
        "$fixture_root" >/dev/null 2>&1; then
        die "prepared performance fixture still contains unresolved SDK path tokens"
    fi
    {
        printf 'mode=prepared-offline-fixture\n'
        printf 'source=%s\n' "$prepared_fixture_root"
        printf 'cocoapods_invoked=no\n'
    } >"$output_root/pod-install.log"
else
    cp -R "$harness_source/." "$fixture_root/"
    (
        cd "$fixture_root"
        "$ruby_bin" generate-project.rb
        TLS_SDK_ROOT="$package_root" SLS_SDK_ROOT="$sls_root" \
            "$pod_bin" install --no-repo-update
    ) >"$output_root/pod-install.log" 2>&1
fi

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
if [[ "$require_idle_host" == 1 && "$host_resource_settle_seconds" -gt 0 ]]; then
    sleep "$host_resource_settle_seconds"
fi
assert_idle_host pre-runs
assert_quiet_host_resources pre-runs

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
if [[ "$require_idle_host" == 1 && "$host_resource_settle_seconds" -gt 0 ]]; then
    sleep "$host_resource_settle_seconds"
fi
capture_host_state "$output_root/host-postflight.txt"
assert_idle_host postflight
assert_quiet_host_resources postflight
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
    xcode-version.txt simulator.txt host-preflight.txt host-postflight.txt \
    host-idle-preflight.txt host-idle-pre-runs.txt host-idle-postflight.txt \
    host-resources-preflight.txt host-resources-pre-runs.txt host-resources-postflight.txt \
    pod-install.log xcodebuild.log certificate-paths.txt ca-install.log server.log \
    server-pid.txt server-cleanup.txt summary.json summary.md \
    runs/*/app-result.json runs/*/server-stats.json runs/*/process-samples.tsv \
    runs/*/app-pid.txt runs/*/process-cleanup.txt >SHA256SUMS)

echo "PASS: performance comparison evidence validated"
echo "OUTPUT_DIR=$output_root"
