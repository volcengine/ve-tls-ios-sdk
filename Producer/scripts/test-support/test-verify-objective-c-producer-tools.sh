#!/usr/bin/env bash
# Exercise Objective-C producer verifier tool discovery without platform builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="${SCRIPT_DIR}/../verify-objective-c-producer.sh"
BASH_BIN="$(command -v bash)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tls-objc-tools.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

utility_dir="${test_root}/utility"
path_tools="${test_root}/path-tools"
wrong_tools="${test_root}/wrong-tools"
override_tools="${test_root}/override-tools"
mkdir -p "${utility_dir}" "${path_tools}" "${wrong_tools}" "${override_tools}"

write_executable() {
    local path="$1"
    shift
    printf '%s\n' "$@" > "${path}"
    chmod +x "${path}"
}

for utility in dirname grep mktemp rm; do
    utility_path="$(command -v "${utility}" || true)"
    if [[ -z "${utility_path}" ]]; then
        echo "FAIL: test requires ${utility}"
        exit 1
    fi
    ln -s "${utility_path}" "${utility_dir}/${utility}"
done
ln -s "${BASH_BIN}" "${utility_dir}/bash"

write_executable "${utility_dir}/uname" \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" Darwin'
write_executable "${utility_dir}/rg" \
    '#!/usr/bin/env bash' \
    'case "${1:-}" in' \
    '  --files) printf "%s\\n" main.m; exit 0 ;;' \
    '  -q|-n) exit 1 ;;' \
    '  *) exit 1 ;;' \
    'esac'

path_ruby_marker="${test_root}/path-ruby.marker"
override_ruby_marker="${test_root}/override-ruby.marker"
write_executable "${path_tools}/pod" '#!/usr/bin/env bash' 'exit 0'
write_executable "${path_tools}/ruby" \
    '#!/usr/bin/env bash' \
    "printf '%s\\n' path-ruby > '${path_ruby_marker}'" \
    'exit 0'
write_executable "${path_tools}/xcodebuild" '#!/usr/bin/env bash' 'exit 0'
write_executable "${path_tools}/xcrun" '#!/usr/bin/env bash' 'exit 0'

# These entries make the override case fail if the verifier silently falls
# back to PATH instead of honoring the explicit tool paths.
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${wrong_tools}/pod"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${wrong_tools}/xcodebuild"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${wrong_tools}/xcrun"
write_executable "${wrong_tools}/ruby" '#!/usr/bin/env bash' 'exit 91'

write_executable "${override_tools}/pod" '#!/usr/bin/env bash' 'exit 0'
write_executable "${override_tools}/ruby" \
    '#!/usr/bin/env bash' \
    "printf '%s\\n' override-ruby > '${override_ruby_marker}'" \
    'exit 0'
write_executable "${override_tools}/xcodebuild" '#!/usr/bin/env bash' 'exit 0'
write_executable "${override_tools}/xcrun" '#!/usr/bin/env bash' 'exit 0'

if grep -Fq '/opt/homebrew' "${VERIFIER}"; then
    echo "FAIL: verifier still contains a machine-specific Homebrew fallback"
    exit 1
fi
for tool in pod ruby; do
    if ! grep -Fq "command -v ${tool}" "${VERIFIER}"; then
        echo "FAIL: verifier does not discover ${tool} through PATH"
        exit 1
    fi
done

run_verifier() {
    local log="$1"
    local path="$2"
    local mode="$3"
    local rc=0
    if (
        unset POD_BIN RUBY_BIN XCODEBUILD_BIN XCRUN_BIN
        unset RUN_IOS_SIMULATOR IOS_SIMULATOR_UDID KEEP_SUCCESS
        export PATH="${path}"
        export SKIP_SWIFTPM=1 SKIP_MACOS=1 SKIP_IOS=1
        if [[ "${mode}" == "override" ]]; then
            export POD_BIN="${override_tools}/pod"
            export RUBY_BIN="${override_tools}/ruby"
            export XCODEBUILD_BIN="${override_tools}/xcodebuild"
            export XCRUN_BIN="${override_tools}/xcrun"
        fi
        "${BASH_BIN}" "${VERIFIER}"
    ) >"${log}" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "${rc}"
}

path_log="${test_root}/path.log"
path_rc="$(run_verifier "${path_log}" "${path_tools}:${utility_dir}" path)"
if [[ "${path_rc}" -ne 0 ]] || ! grep -Fq 'SKIP: no Objective-C producer checks ran.' "${path_log}" ||
   grep -Fq 'BLOCKED:' "${path_log}" || grep -Fq '/opt/homebrew' "${path_log}" ||
   [[ ! -f "${path_ruby_marker}" ]]; then
    echo "FAIL: PATH discovery case did not complete cleanly"
    sed -n '1,80p' "${path_log}"
    exit 1
fi
echo "OK: PATH discovery selected pod/ruby/xcodebuild without machine-specific fallbacks."

override_log="${test_root}/override.log"
override_rc="$(run_verifier "${override_log}" "${wrong_tools}:${utility_dir}" override)"
if [[ "${override_rc}" -ne 0 ]] || ! grep -Fq 'SKIP: no Objective-C producer checks ran.' "${override_log}" ||
   grep -Fq 'BLOCKED:' "${override_log}" || grep -Fq '/opt/homebrew' "${override_log}" ||
   [[ ! -f "${override_ruby_marker}" ]]; then
    echo "FAIL: explicit override case did not complete cleanly"
    sed -n '1,80p' "${override_log}"
    exit 1
fi
echo "OK: explicit POD_BIN/RUBY_BIN/XCODEBUILD_BIN/XCRUN_BIN overrides were honored."

missing_log="${test_root}/missing.log"
missing_rc="$(run_verifier "${missing_log}" "${utility_dir}" missing)"
if [[ "${missing_rc}" -ne 1 ]] ||
   ! grep -Fq 'CocoaPods executable was not found in PATH; set POD_BIN to an executable path' "${missing_log}" ||
   ! grep -Fq 'Ruby executable was not found in PATH; set RUBY_BIN to an executable path' "${missing_log}" ||
   ! grep -Fq 'xcodebuild was not found in PATH; set XCODEBUILD_BIN to an executable path' "${missing_log}" ||
   grep -Fq 'Objective-C producer verification completed' "${missing_log}" ||
   grep -Fq '/opt/homebrew' "${missing_log}"; then
    echo "FAIL: missing-tool case did not report a blocking failure"
    sed -n '1,100p' "${missing_log}"
    exit 1
fi
echo "OK: missing tools are reported as BLOCKED and cannot produce a success summary."

echo "OK: Objective-C producer verifier tool-discovery tests passed."
