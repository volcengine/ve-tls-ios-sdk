#!/bin/bash
set -euo pipefail

script_path=$(cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
runner_root=$(cd -- "$(dirname -- "$script_path")" && pwd)
state_root=$(cd -- "$runner_root/.." && pwd)
metadata_root="$runner_root/metadata"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

read_metadata() {
    local name=$1
    local path="$metadata_root/$name"
    [[ -s "$path" ]] || die "runner metadata is missing: $name"
    sed -n '1p' "$path"
}

select_developer_dir() {
    local developer_dir
    developer_dir=$(read_metadata developer-dir.txt)
    [[ -d "$developer_dir" ]] || die "sealed DEVELOPER_DIR does not exist: $developer_dir"
    export DEVELOPER_DIR="$developer_dir"
}

verify_runner() {
    [[ -f "$runner_root/RUNNER_SHA256SUMS" ]] || die "RUNNER_SHA256SUMS is missing"
    (cd "$runner_root" && shasum -a 256 -c RUNNER_SHA256SUMS >/dev/null)
    printf '%s\n' 'PASS: sealed runner file checksums verified'
    select_developer_dir

    local expected_tls_sha
    local expected_sls_sha
    local expected_sls_tag
    expected_tls_sha=$(read_metadata tls-sha.txt)
    expected_sls_sha=$(read_metadata sls-sha.txt)
    expected_sls_tag=$(read_metadata sls-tag.txt)
    [[ "$(git -C "$runner_root/tls" rev-parse HEAD)" == "$expected_tls_sha" ]] \
        || die "TLS checkout does not match sealed SHA"
    [[ -z "$(git -C "$runner_root/tls" status --porcelain=v1)" ]] \
        || die "TLS checkout is dirty"
    [[ "$(git -C "$runner_root/sls" rev-parse HEAD)" == "$expected_sls_sha" ]] \
        || die "SLS checkout does not match sealed SHA"
    [[ "$(git -C "$runner_root/sls" describe --tags --exact-match)" == "$expected_sls_tag" ]] \
        || die "SLS checkout does not match sealed tag"
    [[ -z "$(git -C "$runner_root/sls" status --porcelain=v1)" ]] \
        || die "SLS checkout is dirty"
}

verify_host() {
    local expected_machine
    local expected_runtime
    local simulator_id
    local actual_xcode
    local actual_runtime
    select_developer_dir
    expected_machine=$(read_metadata machine.txt)
    expected_runtime=$(read_metadata simulator-runtime.txt)
    simulator_id=$(read_metadata simulator-id.txt)

    [[ "$(uname -m)" == "$expected_machine" ]] \
        || die "host architecture $(uname -m) does not match $expected_machine"
    actual_xcode=$(mktemp "${TMPDIR:-/tmp}/tls-offline-xcode.XXXXXX")
    xcodebuild -version >"$actual_xcode"
    if ! cmp -s "$metadata_root/xcode-version.txt" "$actual_xcode"; then
        echo "Expected Xcode:" >&2
        sed -n '1,10p' "$metadata_root/xcode-version.txt" >&2
        echo "Actual Xcode:" >&2
        sed -n '1,10p' "$actual_xcode" >&2
        rm -f "$actual_xcode"
        die "selected Xcode does not match the sealed runner"
    fi
    rm -f "$actual_xcode"

    xcrun simctl shutdown all >/dev/null 2>&1 || true
    xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$simulator_id" -b
    actual_runtime=$(
        xcrun simctl list devices -j | python3 -c '
import json, sys
wanted = sys.argv[1]
data = json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    for device in devices:
        if device.get("udid") == wanted:
            print(runtime)
            raise SystemExit(0)
raise SystemExit(1)
' "$simulator_id"
    )
    [[ "$actual_runtime" == "$expected_runtime" ]] \
        || die "simulator runtime $actual_runtime does not match $expected_runtime"
}

write_partial_checksums() {
    local run_root=$1
    (
        cd "$run_root"
        find . -type f \
            ! -name PARTIAL_SHA256SUMS \
            ! -name controller.log \
            -print | LC_ALL=C sort | while IFS= read -r file; do
                shasum -a 256 "$file"
            done
    ) >"$run_root/PARTIAL_SHA256SUMS"
}

run_matrix() {
    local run_root=$1
    local profile=$2
    local evidence_root="$run_root/evidence"
    local sealed_profile
    local simulator_id
    local warmup_seconds
    local measure_seconds
    local repeats
    local rates
    local modes
    local enforce_gate
    local disk_max
    local cpu_min
    local cpu_mean
    local preflight_settle_seconds
    local result_archive="${run_root}.tar.gz"

    [[ -d "$run_root" ]] || die "run directory does not exist: $run_root"
    sealed_profile=$(read_metadata profile.txt)
    if [[ "$profile" == short && "$sealed_profile" != short ]]; then
        die "sealed $sealed_profile runner cannot execute the short profile"
    fi
    [[ "$profile" == smoke || "$profile" == short ]] \
        || die "unsupported requested runner profile: $profile"
    simulator_id=$(read_metadata simulator-id.txt)
    disk_max=$(read_metadata host-disk-max-mbps.txt)
    cpu_min=$(read_metadata host-cpu-min-idle-percent.txt)
    cpu_mean=$(read_metadata host-cpu-mean-idle-percent.txt)
    preflight_settle_seconds=$(read_metadata preflight-settle-seconds.txt)
    case "$profile" in
        smoke)
            warmup_seconds=1
            measure_seconds=2
            repeats=1
            rates=100
            modes=memory
            enforce_gate=0
            ;;
        short)
            warmup_seconds=10
            measure_seconds=30
            repeats=3
            rates="100 300"
            modes="memory persistent"
            enforce_gate=1
            ;;
        *)
            die "unsupported sealed runner profile: $profile"
            ;;
    esac

    finalize() {
        local rc=$?
        trap - EXIT INT TERM
        if [[ "$rc" == 0 ]]; then
            printf 'result=passed\nexit_code=0\n' >"$run_root/RUN_STATUS.txt"
        else
            printf 'result=failed\nexit_code=%s\n' "$rc" >"$run_root/RUN_STATUS.txt"
        fi
        write_partial_checksums "$run_root"
        /usr/bin/tar -czf "$result_archive" \
            -C "$(dirname -- "$run_root")" "$(basename -- "$run_root")"
        (
            cd -- "$(dirname -- "$result_archive")"
            archive_name=$(basename -- "$result_archive")
            shasum -a 256 "$archive_name" >"${archive_name}.sha256"
        )
        exit "$rc"
    }
    trap finalize EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    verify_runner
    verify_host
    mkdir -p "$evidence_root" "$run_root/tmp"
    : >"$run_root/.metadata_never_index"
    {
        printf 'profile=%s\n' "$profile"
        printf 'sealed_profile=%s\n' "$sealed_profile"
        printf 'network_contract=loopback-only\n'
        printf 'prepared_fixture=yes\n'
        printf 'cocoapods_required_at_run_time=no\n'
        printf 'started_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'preflight_settle_seconds=%s\n' "$preflight_settle_seconds"
    } >"$run_root/RUN_METADATA.txt"
    /sbin/ifconfig >"$run_root/network-interfaces.txt"
    /usr/sbin/netstat -rn >"$run_root/network-routes.txt"
    if [[ "$preflight_settle_seconds" -gt 0 ]]; then
        printf 'Waiting %s seconds for the sealed host preflight settle window.\n' \
            "$preflight_settle_seconds"
        sleep "$preflight_settle_seconds"
    fi

    TMPDIR="$run_root/tmp/" \
    TLS_PERF_SLS_ROOT="$runner_root/sls" \
    TLS_PERF_PREPARED_FIXTURE_ROOT="$runner_root/prepared-fixture" \
    TLS_PERF_EXPECT_APP_ARCH="$(read_metadata machine.txt)" \
    TLS_PERF_SIMULATOR_ID="$simulator_id" \
    TLS_PERF_OUTPUT_DIR="$evidence_root" \
    TLS_PERF_WARMUP_SECONDS="$warmup_seconds" \
    TLS_PERF_MEASURE_SECONDS="$measure_seconds" \
    TLS_PERF_REPEATS="$repeats" \
    TLS_PERF_RATES="$rates" \
    TLS_PERF_MODES="$modes" \
    TLS_PERF_REQUIRE_CLEAN=1 \
    TLS_PERF_REQUIRE_IDLE_HOST=1 \
    TLS_PERF_HOST_CPU_MIN_IDLE_PERCENT="$cpu_min" \
    TLS_PERF_HOST_CPU_MEAN_IDLE_PERCENT="$cpu_mean" \
    TLS_PERF_HOST_DISK_MAX_MEGABYTES_PER_SECOND="$disk_max" \
    TLS_PERF_ENFORCE_GATE="$enforce_gate" \
        "$runner_root/tls/Producer/scripts/performance/run-comparison.sh"
    (cd "$evidence_root" && shasum -a 256 -c SHA256SUMS)
    finalize
}

start_matrix() {
    local profile=$1
    verify_runner
    verify_host
    local sealed_profile
    local timestamp
    local run_root
    local controller_pid
    sealed_profile=$(read_metadata profile.txt)
    if [[ "$profile" == short && "$sealed_profile" != short ]]; then
        die "sealed $sealed_profile runner cannot execute the short profile"
    fi
    [[ "$profile" == smoke || "$profile" == short ]] \
        || die "unsupported requested runner profile: $profile"
    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    run_root="$state_root/tls-performance-${profile}-${timestamp}"
    [[ ! -e "$run_root" ]] || die "run directory already exists: $run_root"
    mkdir -p "$run_root"
    : >"$run_root/.metadata_never_index"
    printf '%s\n' "$run_root" >"$state_root/.tls-performance-last-run"
    /usr/bin/nohup /usr/bin/caffeinate -dims \
        "$script_path" run "$run_root" "$profile" \
        >"$run_root/controller.log" 2>&1 </dev/null &
    controller_pid=$!
    printf '%s\n' "$controller_pid" >"$run_root/controller.pid"
    printf 'STARTED profile=%s pid=%s output=%s\n' \
        "$profile" "$controller_pid" "$run_root"
}

show_status() {
    local last_run_file="$state_root/.tls-performance-last-run"
    [[ -s "$last_run_file" ]] || die "no offline performance run has been started"
    local run_root
    local pid
    run_root=$(sed -n '1p' "$last_run_file")
    printf 'output=%s\n' "$run_root"
    if [[ -s "$run_root/RUN_STATUS.txt" ]]; then
        sed -n '1,20p' "$run_root/RUN_STATUS.txt"
    elif [[ -s "$run_root/controller.pid" ]]; then
        pid=$(sed -n '1p' "$run_root/controller.pid")
        if kill -0 "$pid" 2>/dev/null; then
            printf 'result=running\npid=%s\n' "$pid"
        else
            printf 'result=stopped-without-final-status\npid=%s\n' "$pid"
        fi
    else
        printf 'result=unknown\n'
    fi
    if [[ -s "$run_root/controller.log" ]]; then
        printf '%s\n' 'controller_log_tail_begin'
        tail -n 30 "$run_root/controller.log"
        printf '%s\n' 'controller_log_tail_end'
    fi
}

case "${1:-start}" in
    start)
        start_matrix "$(read_metadata profile.txt)"
        ;;
    smoke)
        start_matrix smoke
        ;;
    status)
        show_status
        ;;
    verify)
        verify_runner
        verify_host
        printf '%s\n' 'PASS: sealed offline runner and Intel host verified'
        ;;
    run)
        [[ $# == 3 ]] || die "internal run mode requires output directory and profile"
        run_matrix "$2" "$3"
        ;;
    *)
        die "usage: $0 [smoke|start|status|verify]"
        ;;
esac
