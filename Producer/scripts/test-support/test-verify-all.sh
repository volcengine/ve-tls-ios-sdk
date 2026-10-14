#!/usr/bin/env bash
# Exercise the summary without running platform builds or network checks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/tls-summary-test.XXXXXX")"
trap 'rm -rf "${fixture}"' EXIT
cp "${SCRIPT_DIR}/../verify-all.sh" "${fixture}/verify-all.sh"

summary_arg_log="${fixture}/core-version-args.log"

for script in verify-core-version.sh verify-core-vendor.sh verify-public-symbols.sh verify-producer-packages.sh verify-objective-c-producer.sh; do
    if [[ "${script}" == "verify-core-version.sh" ]]; then
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'set -euo pipefail' \
            'if [[ -n "${SUMMARY_ARG_LOG:-}" ]]; then' \
            '    if [[ "$#" -eq 0 ]]; then : > "${SUMMARY_ARG_LOG}"; else printf "%s\\n" "$@" > "${SUMMARY_ARG_LOG}"; fi' \
            'fi' \
            'case "${SUMMARY_TEST_CASE}" in' \
            '  blocked) echo "CORE_VERSION status: BLOCKED"; echo "FAIL: unavailable Core"; exit 1 ;;' \
            '  *) echo "OK: fixture core"; exit 0 ;;' \
            'esac' \
            > "${fixture}/${script}"
    else
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'if [[ "$#" -ne 0 ]]; then echo "FAIL: non-core script received arguments"; exit 9; fi' \
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
    fi
    chmod +x "${fixture}/${script}"
done

for test_case in success failure nonzero skip unknown blocked; do
    rc=0
    SUMMARY_ARG_LOG="${summary_arg_log}" SUMMARY_TEST_CASE="${test_case}" \
        bash "${fixture}/verify-all.sh" > "${fixture}/result.log" 2>&1 || rc=$?
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
    if [[ "$(cat "${summary_arg_log}")" != "--release" ]]; then
        echo "FAIL: default verify-all mode did not forward --release"
        cat "${fixture}/result.log"
        exit 1
    fi
    echo "OK: ${test_case} summary"
done

for mode in --release --integration; do
    rc=0
    SUMMARY_ARG_LOG="${summary_arg_log}" SUMMARY_TEST_CASE=success \
        bash "${fixture}/verify-all.sh" "${mode}" > "${fixture}/result-${mode#--}.log" 2>&1 || rc=$?
    if [[ "${rc}" -ne 0 ]] || [[ "$(cat "${summary_arg_log}")" != "${mode}" ]]; then
        echo "FAIL: ${mode} was not forwarded only to verify-core-version.sh"
        cat "${fixture}/result-${mode#--}.log"
        exit 1
    fi
    echo "OK: ${mode} forwarding"
done

rc=0
bash "${fixture}/verify-all.sh" --invalid > "${fixture}/result-invalid.log" 2>&1 || rc=$?
if [[ "${rc}" -ne 2 ]]; then
    echo "FAIL: invalid verify-all argument expected exit=2, got exit=${rc}"
    cat "${fixture}/result-invalid.log"
    exit 1
fi
echo 'OK: invalid verify-all argument'
