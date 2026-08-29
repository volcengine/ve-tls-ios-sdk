#!/bin/bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
package_root=$(cd -- "$script_dir/../../.." && pwd)
sls_root=${TLS_PERF_SLS_ROOT:-"$package_root/../aliyun-log-ios-sdk"}
output_archive=${1:-}
profile=${TLS_OFFLINE_PROFILE:-short}
simulator_id=${TLS_OFFLINE_SIMULATOR_ID:-}
simulator_runtime=${TLS_OFFLINE_SIMULATOR_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-18-5}
expected_machine=${TLS_OFFLINE_EXPECT_MACHINE:-x86_64}
expected_developer_dir=${TLS_OFFLINE_DEVELOPER_DIR:-/Users/xiayangyang/Downloads/IntelRunner/Xcode16.4-expanded/Xcode.app/Contents/Developer}
expected_xcode_name=${TLS_OFFLINE_XCODE_NAME:-Xcode 16.4}
expected_xcode_build=${TLS_OFFLINE_XCODE_BUILD:-Build version 16F6}
host_cpu_min=${TLS_OFFLINE_HOST_CPU_MIN_IDLE_PERCENT:-90}
host_cpu_mean=${TLS_OFFLINE_HOST_CPU_MEAN_IDLE_PERCENT:-92}
host_disk_max=${TLS_OFFLINE_HOST_DISK_MAX_MEGABYTES_PER_SECOND:-1}
preflight_settle_seconds=${TLS_OFFLINE_PREFLIGHT_SETTLE_SECONDS:-300}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -n "$output_archive" ]] || die "usage: $0 /absolute/output/archive.tar.gz"
[[ "$output_archive" == /* ]] || die "output archive must be an absolute path"
[[ "$output_archive" == *.tar.gz ]] || die "output archive must end in .tar.gz"
[[ ! -e "$output_archive" && ! -e "${output_archive}.sha256" ]] \
    || die "output archive or checksum already exists"
[[ -d "$(dirname -- "$output_archive")" ]] || die "output directory does not exist"
[[ "$profile" == smoke || "$profile" == short || "$profile" == long ]] \
    || die "profile must be smoke, short, or long"
[[ "$simulator_id" =~ ^[0-9A-Fa-f-]{36}$ ]] || die "TLS_OFFLINE_SIMULATOR_ID must be one exact UUID"
[[ "$simulator_runtime" =~ ^com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9-]+$ ]] \
    || die "invalid simulator runtime identifier"
[[ "$expected_machine" == x86_64 || "$expected_machine" == arm64 ]] \
    || die "expected machine must be x86_64 or arm64"
[[ "$expected_developer_dir" == /* ]] || die "TLS_OFFLINE_DEVELOPER_DIR must be absolute"
[[ "$host_cpu_min" =~ ^([0-9]+)(\.[0-9]+)?$ ]] || die "invalid CPU minimum"
[[ "$host_cpu_mean" =~ ^([0-9]+)(\.[0-9]+)?$ ]] || die "invalid CPU mean"
[[ "$host_disk_max" =~ ^([0-9]+)(\.[0-9]+)?$ ]] || die "invalid disk maximum"
[[ "$preflight_settle_seconds" =~ ^[0-9]+$ ]] || die "invalid preflight settle seconds"
for percent in "$host_cpu_min" "$host_cpu_mean"; do
    awk -v value="$percent" 'BEGIN { exit !(value >= 0 && value <= 100) }' \
        || die "CPU thresholds must be within 0...100"
done

[[ -d "$package_root/.git" ]] || die "TLS repository not found"
[[ -d "$sls_root/.git" ]] || die "SLS repository not found: $sls_root"
[[ -z "$(git -C "$package_root" status --porcelain=v1)" ]] \
    || die "TLS repository must be clean before sealing an offline runner"
[[ -z "$(git -C "$sls_root" status --porcelain=v1)" ]] \
    || die "SLS repository must be clean before sealing an offline runner"
sls_tag=$(git -C "$sls_root" describe --tags --exact-match 2>/dev/null || true)
[[ "$sls_tag" == 4.3.4 ]] || die "SLS repository must be exact tag 4.3.4"

pod_bin=${POD_BIN:-$(command -v pod || true)}
if [[ -z "$pod_bin" && -x /opt/homebrew/lib/ruby/gems/3.3.0/bin/pod ]]; then
    pod_bin=/opt/homebrew/lib/ruby/gems/3.3.0/bin/pod
fi
[[ -x "$pod_bin" ]] || die "CocoaPods executable not found on the packaging host"
ruby_bin=${RUBY_BIN:-/opt/homebrew/opt/ruby@3.3/bin/ruby}
[[ -x "$ruby_bin" ]] || ruby_bin=$(command -v ruby || true)
[[ -x "$ruby_bin" ]] || die "Ruby executable not found on the packaging host"
"$ruby_bin" -rxcodeproj -e 'abort unless Gem::Version.new(Xcodeproj::VERSION) >= Gem::Version.new("1.20")' \
    || die "Ruby xcodeproj gem is unavailable on the packaging host"

tls_sha=$(git -C "$package_root" rev-parse HEAD)
sls_sha=$(git -C "$sls_root" rev-parse HEAD)
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/tls-offline-runner.XXXXXX")
runner_name="tls-offline-performance-${profile}-${tls_sha:0:12}"
runner_root="$staging_root/$runner_name"

cleanup() {
    rm -rf "$staging_root"
}
trap cleanup EXIT INT TERM

mkdir -p "$runner_root/metadata"
: >"$runner_root/.metadata_never_index"
git clone --quiet --no-local "$package_root" "$runner_root/tls"
git -C "$runner_root/tls" checkout --quiet --detach "$tls_sha"
git -C "$runner_root/tls" remote remove origin
git clone --quiet --no-local "$sls_root" "$runner_root/sls"
git -C "$runner_root/sls" checkout --quiet --detach "$sls_sha"
git -C "$runner_root/sls" remote remove origin
[[ -z "$(git -C "$runner_root/tls" status --porcelain=v1)" ]] \
    || die "sealed TLS checkout is dirty"
[[ -z "$(git -C "$runner_root/sls" status --porcelain=v1)" ]] \
    || die "sealed SLS checkout is dirty"

prepared_fixture="$runner_root/prepared-fixture"
mkdir -p "$prepared_fixture"
cp -R "$runner_root/tls/Producer/Examples/PerformanceHarness/." "$prepared_fixture/"
(
    cd "$prepared_fixture"
    "$ruby_bin" generate-project.rb
    TLS_SDK_ROOT="$runner_root/tls" SLS_SDK_ROOT="$runner_root/sls" \
        "$pod_bin" install --no-repo-update
) >"$prepared_fixture/PREPARE_PODS.log" 2>&1

pods_project="$prepared_fixture/Pods/Pods.xcodeproj/project.pbxproj"
perl -pi -e '
    s#path = ".*/Pods/Target Support Files/VolcengineTLSProducer";#path = "__TLS_SUPPORT_FILES_RELATIVE__";#g;
    s#path = ".*/Pods/Target Support Files/AliyunLogProducer";#path = "__SLS_SUPPORT_FILES_RELATIVE__";#g;
' "$pods_project"
[[ "$(/usr/bin/grep -c '__TLS_SUPPORT_FILES_RELATIVE__' "$pods_project")" == 1 ]] \
    || die "prepared fixture did not isolate the TLS support-files group"
[[ "$(/usr/bin/grep -c '__SLS_SUPPORT_FILES_RELATIVE__' "$pods_project")" == 1 ]] \
    || die "prepared fixture did not isolate the SLS support-files group"
if /usr/bin/grep -n '/Pods/Target Support Files/' "$pods_project" >/dev/null 2>&1; then
    die "prepared fixture still contains an unsealed support-files path"
fi

replace_prepared_path_if_present() {
    local source_path=$1
    local replacement=$2
    local files
    files=$(/usr/bin/grep -rl -F -- "$source_path" "$prepared_fixture" || true)
    [[ -n "$files" ]] || return 1
    while IFS= read -r file; do
        SOURCE_PATH_VALUE="$source_path" REPLACEMENT_VALUE="$replacement" \
            perl -pi -e 's/\Q$ENV{SOURCE_PATH_VALUE}\E/$ENV{REPLACEMENT_VALUE}/g' "$file"
    done <<<"$files"
}

replace_prepared_root() {
    local source_path=$1
    local replacement=$2
    local candidate_path
    local path_alias
    local physical_path
    local replaced=0
    physical_path=$(cd -- "$source_path" && pwd -P)
    for candidate_path in "$physical_path" "$source_path"; do
        if replace_prepared_path_if_present "$candidate_path" "$replacement"; then
            replaced=1
        fi
        if [[ "$candidate_path" == /private/* ]]; then
            path_alias=${candidate_path#/private}
        else
            path_alias=/private$candidate_path
        fi
        if replace_prepared_path_if_present "$path_alias" "$replacement"; then
            replaced=1
        fi
    done
    [[ "$replaced" == 1 ]] \
        || die "prepared fixture did not record expected path: $source_path"
}

replace_prepared_root "$runner_root/tls" '__TLS_SDK_ROOT__'
replace_prepared_root "$runner_root/sls" '__SLS_SDK_ROOT__'
tokenized_path_files=$(
    /usr/bin/grep -rl \
        -e '__TLS_SDK_ROOT__' \
        -e '__SLS_SDK_ROOT__' \
        "$prepared_fixture" || true
)
[[ -n "$tokenized_path_files" ]] \
    || die "prepared fixture has no tokenized SDK paths"
while IFS= read -r tokenized_path_file; do
    perl -pi -e '
        s#(?:\.\./)*\.\.__TLS_SDK_ROOT__#__TLS_SDK_ROOT__#g;
        s#(?:\.\./)*\.\.__SLS_SDK_ROOT__#__SLS_SDK_ROOT__#g;
    ' "$tokenized_path_file"
done <<<"$tokenized_path_files"
find "$prepared_fixture/Pods/Target Support Files" -type f -name '*.xcconfig' \
    -exec perl -pi -e '
        s#\$\{PODS_ROOT\}(?:/\.\.)+__TLS_SDK_ROOT__#__TLS_SDK_ROOT__#g;
        s#\$\{PODS_ROOT\}(?:/\.\.)+__SLS_SDK_ROOT__#__SLS_SDK_ROOT__#g;
        s#\$\{PODS_ROOT\}/__TLS_SDK_ROOT__#__TLS_SDK_ROOT__#g;
        s#\$\{PODS_ROOT\}/__SLS_SDK_ROOT__#__SLS_SDK_ROOT__#g;
    ' {} +
if /usr/bin/grep -r -E \
    '\$\{PODS_ROOT\}.*__(TLS|SLS)_SDK_ROOT__' \
    "$prepared_fixture" >/dev/null 2>&1; then
    die "prepared fixture contains a non-canonical SDK path token"
fi
staging_root_physical=$(cd -- "$staging_root" && pwd -P)
if [[ "$staging_root_physical" == /private/* ]]; then
    staging_root_alias=${staging_root_physical#/private}
else
    staging_root_alias=/private$staging_root_physical
fi
for sealed_staging_path in \
    "$staging_root_physical" \
    "$staging_root_alias" \
    "$staging_root"; do
    if /usr/bin/grep -r -F -- "$sealed_staging_path" "$prepared_fixture" >/dev/null 2>&1; then
        die "prepared fixture still contains a packaging-host staging path"
    fi
done
if /usr/bin/grep -r -E \
    '\.\.__(TLS|SLS)_SDK_ROOT__' \
    "$prepared_fixture" >/dev/null 2>&1; then
    die "prepared fixture contains an SDK token joined to parent traversal"
fi
if /usr/bin/grep -r -F -- "$package_root" "$prepared_fixture" >/dev/null 2>&1; then
    die "prepared fixture still contains the packaging-host TLS path"
fi
if /usr/bin/grep -r -F -- "$sls_root" "$prepared_fixture" >/dev/null 2>&1; then
    die "prepared fixture still contains the packaging-host SLS path"
fi

cp "$runner_root/tls/Producer/scripts/performance/offline-runner.sh" \
    "$runner_root/run-offline-performance.sh"
chmod +x "$runner_root/run-offline-performance.sh"
cp "$runner_root/tls/Producer/Examples/PerformanceHarness/OFFLINE_RUNNER.md" \
    "$runner_root/README.md"

printf '%s\n' "$tls_sha" >"$runner_root/metadata/tls-sha.txt"
printf '%s\n' "$sls_sha" >"$runner_root/metadata/sls-sha.txt"
printf '%s\n' "$sls_tag" >"$runner_root/metadata/sls-tag.txt"
printf '%s\n' "$profile" >"$runner_root/metadata/profile.txt"
printf '%s\n' "$expected_machine" >"$runner_root/metadata/machine.txt"
printf '%s\n' "$expected_developer_dir" >"$runner_root/metadata/developer-dir.txt"
printf '%s\n%s\n' "$expected_xcode_name" "$expected_xcode_build" \
    >"$runner_root/metadata/xcode-version.txt"
printf '%s\n' "$simulator_id" >"$runner_root/metadata/simulator-id.txt"
printf '%s\n' "$simulator_runtime" >"$runner_root/metadata/simulator-runtime.txt"
printf '%s\n' "$host_cpu_min" >"$runner_root/metadata/host-cpu-min-idle-percent.txt"
printf '%s\n' "$host_cpu_mean" >"$runner_root/metadata/host-cpu-mean-idle-percent.txt"
printf '%s\n' "$host_disk_max" >"$runner_root/metadata/host-disk-max-mbps.txt"
printf '%s\n' "$preflight_settle_seconds" >"$runner_root/metadata/preflight-settle-seconds.txt"

(
    cd "$runner_root"
    find . \
        -path './tls/.git' -prune -o \
        -path './sls/.git' -prune -o \
        -type f ! -name RUNNER_SHA256SUMS -print | LC_ALL=C sort \
        | while IFS= read -r file; do
            shasum -a 256 "$file"
        done
) >"$runner_root/RUNNER_SHA256SUMS"
(cd "$runner_root" && shasum -a 256 -c RUNNER_SHA256SUMS >/dev/null)

COPYFILE_DISABLE=1 /usr/bin/tar -czf "$output_archive" \
    -C "$staging_root" "$runner_name"
(
    cd -- "$(dirname -- "$output_archive")"
    archive_name=$(basename -- "$output_archive")
    shasum -a 256 "$archive_name" >"${archive_name}.sha256"
)
printf 'PASS: sealed offline performance runner created\n'
printf 'TLS_SHA=%s\n' "$tls_sha"
printf 'SLS_SHA=%s\n' "$sls_sha"
printf 'PROFILE=%s\n' "$profile"
printf 'ARCHIVE=%s\n' "$output_archive"
printf 'ARCHIVE_SHA256=%s\n' "$(awk '{ print $1 }' "${output_archive}.sha256")"
