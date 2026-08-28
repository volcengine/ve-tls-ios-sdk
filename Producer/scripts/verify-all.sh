#!/usr/bin/env bash
#
# verify-all.sh — run all Producer verification scripts and summarize.
#
# Runs in order:
#   verify-core-version.sh   (the Core release gate)
#   verify-public-symbols.sh (SKIPs without macOS/built product)
#   verify-consumer-packages.sh (SKIPs without macOS toolchain)
#   verify-legacy-sdk.sh     (diff guard; SKIPs legacy tests without macOS)
#
# Prints a PASS/FAIL/SKIP summary table.
#
# Exit code: non-zero if any script FAILs. A deliberately BLOCKED Core gate is
# reported as BLOCKED and does not fail this aggregation; an unexpected Core
# gate failure (missing/malformed registry or a failed ACCEPTED check) does.
#
# Environment: any (individual scripts SKIP on unsupported platforms).
# Evidence level: aggregation only; see each script's header for its limits.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scripts=(
    "verify-core-version.sh"
    "verify-public-symbols.sh"
    "verify-consumer-packages.sh"
    "verify-legacy-sdk.sh"
)

exit_code=0

# Bash 3.2 (the system Bash on supported macOS releases) has no associative
# arrays. Keep the fixed four-entry result table in ordinary variables instead
# of requiring a newer shell just to aggregate script output.
result_verify_core_version="UNKNOWN"
result_verify_public_symbols="UNKNOWN"
result_verify_consumer_packages="UNKNOWN"
result_verify_legacy_sdk="UNKNOWN"

set_result() {
    case "$1" in
        verify-core-version.sh) result_verify_core_version="$2" ;;
        verify-public-symbols.sh) result_verify_public_symbols="$2" ;;
        verify-consumer-packages.sh) result_verify_consumer_packages="$2" ;;
        verify-legacy-sdk.sh) result_verify_legacy_sdk="$2" ;;
        *) return 1 ;;
    esac
}

get_result() {
    case "$1" in
        verify-core-version.sh) printf '%s' "$result_verify_core_version" ;;
        verify-public-symbols.sh) printf '%s' "$result_verify_public_symbols" ;;
        verify-consumer-packages.sh) printf '%s' "$result_verify_consumer_packages" ;;
        verify-legacy-sdk.sh) printf '%s' "$result_verify_legacy_sdk" ;;
        *) printf '%s' "UNKNOWN" ;;
    esac
}

echo "=========================================="
echo " VolcengineTLSProducer verification suite"
echo "=========================================="

for script in "${scripts[@]}"; do
    path="${SCRIPT_DIR}/${script}"
    echo ""
    echo "--- ${script} ---"
    if [[ ! -f "${path}" ]]; then
        echo "SKIP: ${script} not found"
        set_result "${script}" "SKIP"
        continue
    fi
    output=""
    if output="$("${path}" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    echo "${output}"
    if [[ ${rc} -ne 0 ]]; then
        # A blocked Core gate is an expected state during an unreleased
        # checkout. Do not hide any other Core failure behind that exception.
        if [[ "${script}" == "verify-core-version.sh" ]] && \
           echo "${output}" | grep -q '^CORE_VERSION status: BLOCKED'; then
            set_result "${script}" "BLOCKED"
        else
            set_result "${script}" "FAIL"
            exit_code=1
        fi
    elif echo "${output}" | grep -q "FAIL:"; then
        # Non-zero exit already handled above; this catches nothing new,
        # kept for clarity.
        set_result "${script}" "FAIL"
        exit_code=1
    elif echo "${output}" | grep -q "PASS:"; then
        # A script that printed an explicit PASS line is PASS even if it
        # also printed SKIP lines for optional sections (e.g. legacy-sdk).
        set_result "${script}" "PASS"
    elif echo "${output}" | grep -q "SKIP"; then
        set_result "${script}" "SKIP"
    else
        set_result "${script}" "UNKNOWN"
        exit_code=1
    fi
done

echo ""
echo "=========================================="
echo " Summary"
echo "=========================================="
printf "%-34s %s\n" "Script" "Result"
printf "%-34s %s\n" "------" "------"
for script in "${scripts[@]}"; do
    printf "%-34s %s\n" "${script}" "$(get_result "${script}")"
done
echo "=========================================="
echo "NOTE: a deliberately BLOCKED C Core gate is reported as BLOCKED;"
echo "      any unexpected FAIL fails this suite (exit code ${exit_code})."
exit "${exit_code}"
