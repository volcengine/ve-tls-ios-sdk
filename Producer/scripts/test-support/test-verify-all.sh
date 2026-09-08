#!/usr/bin/env bash
# Exercise the summary without running platform builds or network checks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/tls-summary-test.XXXXXX")"
trap 'rm -rf "${fixture}"' EXIT
cp "${SCRIPT_DIR}/../verify-all.sh" "${fixture}/verify-all.sh"

for script in verify-core-version.sh verify-core-vendor.sh verify-public-symbols.sh verify-producer-packages.sh verify-objective-c-producer.sh; do
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "${0##*/}" == "verify-core-version.sh" && "${SUMMARY_TEST_CASE}" == "blocked" ]]; then echo "CORE_VERSION status: BLOCKED"; echo "FAIL: unavailable Core"; exit 1; fi' \
        'if [[ "${0##*/}" != "verify-producer-packages.sh" ]]; then echo "OK: fixture"; exit 0; fi' \
        'case "${SUMMARY_TEST_CASE}" in' \
        '  success) echo "OK: first check" ;;' \
        '  failure) echo "FAIL: first check" ;;' \
        '  nonzero) echo "OK: completed first check"; exit 7 ;;' \
        '  skip) echo "SKIP: optional check"; exit 0 ;;' \
        '  unknown) echo "unrecognized output"; exit 0 ;;' \
        'esac' \
        'awk '\''BEGIN { for (i=0; i<20000; i++) print "compiler output compiler output compiler output" }'\''' \
        'echo "OK: final check"' > "${fixture}/${script}"
    chmod +x "${fixture}/${script}"
done

for test_case in success failure nonzero skip unknown blocked; do
    rc=0
    SUMMARY_TEST_CASE="${test_case}" bash "${fixture}/verify-all.sh" > "${fixture}/result.log" 2>&1 || rc=$?
    case "${test_case}" in
        success) expected_rc=0; expected_result=PASS ;;
        skip) expected_rc=0; expected_result=SKIP ;;
        unknown) expected_rc=1; expected_result=UNKNOWN ;;
        *) expected_rc=1; expected_result=FAIL ;;
    esac
    checked_script=verify-producer-packages.sh
    if [[ "${test_case}" == "blocked" ]]; then
        checked_script=verify-core-version.sh
        expected_result=BLOCKED
    fi
    if [[ "${rc}" -ne "${expected_rc}" ]] ||
       ! grep -Eq "^${checked_script}[[:space:]]+${expected_result}$" "${fixture}/result.log"; then
        echo "FAIL: ${test_case} expected exit=${expected_rc} result=${expected_result}, got exit=${rc}"
        tail -12 "${fixture}/result.log"
        exit 1
    fi
    echo "OK: ${test_case} summary"
done
