#!/usr/bin/env bash
#
# verify-all.sh — run all Producer verification scripts and summarize.
#
# Runs in order:
#   verify-core-version.sh   (the Core release gate)
#   verify-core-vendor.sh    (vendored source integrity and optional source comparison)
#   verify-public-symbols.sh (SKIPs without macOS/built product)
#   verify-consumer-packages.sh (SKIPs without macOS toolchain)
#   verify-objective-c-consumer.sh (pure Objective-C package consumers)
#
# Prints a PASS/FAIL/SKIP summary table.
#
# Exit code: non-zero on a failed, blocked, or unrecognized check. Explicit
# skips are reported separately and do not count as executed checks.
#
# Environment: any (individual scripts SKIP on unsupported platforms).
# Evidence level: aggregation only; see each script's header for its limits.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scripts=(
    "verify-core-version.sh"
    "verify-core-vendor.sh"
    "verify-public-symbols.sh"
    "verify-consumer-packages.sh"
    "verify-objective-c-consumer.sh"
)

exit_code=0

# Bash 3.2 (the system Bash on supported macOS releases) has no associative
# arrays. Keep the fixed result table in ordinary variables instead
# of requiring a newer shell just to aggregate script output.
result_verify_core_version="UNKNOWN"
result_verify_core_vendor="UNKNOWN"
result_verify_public_symbols="UNKNOWN"
result_verify_consumer_packages="UNKNOWN"
result_verify_objective_c_consumer="UNKNOWN"

set_result() {
    case "$1" in
        verify-core-version.sh) result_verify_core_version="$2" ;;
        verify-core-vendor.sh) result_verify_core_vendor="$2" ;;
        verify-public-symbols.sh) result_verify_public_symbols="$2" ;;
        verify-consumer-packages.sh) result_verify_consumer_packages="$2" ;;
        verify-objective-c-consumer.sh) result_verify_objective_c_consumer="$2" ;;
        *) return 1 ;;
    esac
}

get_result() {
    case "$1" in
        verify-core-version.sh) printf '%s' "$result_verify_core_version" ;;
        verify-core-vendor.sh) printf '%s' "$result_verify_core_vendor" ;;
        verify-public-symbols.sh) printf '%s' "$result_verify_public_symbols" ;;
        verify-consumer-packages.sh) printf '%s' "$result_verify_consumer_packages" ;;
        verify-objective-c-consumer.sh) printf '%s' "$result_verify_objective_c_consumer" ;;
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
        # Keep unavailable Core dependencies labeled BLOCKED while failing
        # the suite, rather than conflating them with other check failures.
        if [[ "${script}" == "verify-core-version.sh" ]] && \
           grep -q '^CORE_VERSION status: BLOCKED' <<< "${output}"; then
            set_result "${script}" "BLOCKED"
            exit_code=1
        else
            set_result "${script}" "FAIL"
            exit_code=1
        fi
    elif grep -q "FAIL:" <<< "${output}"; then
        # Reject failure output even if a child script incorrectly exits zero.
        set_result "${script}" "FAIL"
        exit_code=1
    elif grep -q "OK:" <<< "${output}"; then
        # A script that printed an explicit OK line is successful even if it
        # also printed SKIP lines for optional sections. Here-strings avoid
        # echo receiving SIGPIPE when grep -q stops before a long build log ends.
        set_result "${script}" "PASS"
    elif grep -q "SKIP" <<< "${output}"; then
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
echo "NOTE: failed, blocked, or unrecognized checks fail this suite (exit code ${exit_code})."
exit "${exit_code}"
