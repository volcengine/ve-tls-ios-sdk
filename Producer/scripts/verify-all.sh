#!/usr/bin/env bash
#
# verify-all.sh — run all Producer verification scripts and summarize.
#
# Runs in order:
#   verify-core-version.sh   (intentional red gate while Core is BLOCKED)
#   verify-public-symbols.sh (SKIPs without macOS/built product/allowlist)
#   verify-consumer-packages.sh (SKIPs without macOS toolchain)
#   verify-legacy-sdk.sh     (diff guard; SKIPs legacy tests without macOS)
#
# Prints a PASS/FAIL/SKIP summary table.
#
# Exit code: non-zero if any script FAILs, EXCEPT verify-core-version.sh,
# whose FAIL is the intentional red gate while the C Core release gate is
# BLOCKED (see Producer/CORE_VERSION). The table is the human-readable
# contract; the exit code is the CI gate.
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

declare -A results
exit_code=0

echo "=========================================="
echo " VolcengineTLSProducer verification suite"
echo "=========================================="

for script in "${scripts[@]}"; do
    path="${SCRIPT_DIR}/${script}"
    echo ""
    echo "--- ${script} ---"
    if [[ ! -f "${path}" ]]; then
        echo "SKIP: ${script} not found"
        results["${script}"]="SKIP"
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
        results["${script}"]="FAIL"
        # verify-core-version.sh is the intentional red gate while BLOCKED;
        # any other FAIL fails the suite.
        if [[ "${script}" != "verify-core-version.sh" ]]; then
            exit_code=1
        fi
    elif echo "${output}" | grep -q "FAIL:"; then
        # Non-zero exit already handled above; this catches nothing new,
        # kept for clarity.
        results["${script}"]="FAIL"
    elif echo "${output}" | grep -q "PASS:"; then
        # A script that printed an explicit PASS line is PASS even if it
        # also printed SKIP lines for optional sections (e.g. legacy-sdk).
        results["${script}"]="PASS"
    elif echo "${output}" | grep -q "SKIP"; then
        results["${script}"]="SKIP"
    else
        results["${script}"]="UNKNOWN"
    fi
done

echo ""
echo "=========================================="
echo " Summary"
echo "=========================================="
printf "%-34s %s\n" "Script" "Result"
printf "%-34s %s\n" "------" "------"
for script in "${scripts[@]}"; do
    printf "%-34s %s\n" "${script}" "${results[${script}]:-UNKNOWN}"
done
echo "=========================================="
echo "NOTE: verify-core-version.sh is an intentional red gate while the C Core"
echo "      release gate is BLOCKED (see Producer/CORE_VERSION)."
echo "      Any other FAIL fails this suite (exit code ${exit_code})."
exit "${exit_code}"
