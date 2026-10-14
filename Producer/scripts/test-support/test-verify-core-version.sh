#!/usr/bin/env bash
# Exercise verify-core-version.sh in both release and integration modes.
set -euo pipefail

regression_log="/tmp/tls-ios-p1-core-gate-regressions.log"
: > "${regression_log}"
exec 3>&1
exec > "${regression_log}" 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/tls-core-version-test.XXXXXX")"
vendor_fixture="$(mktemp -d "${TMPDIR:-/tmp}/tls-core-vendor-test.XXXXXX")"
cleanup() {
    local rc=$?
    cat "${regression_log}" >&3
    rm -rf -- "${fixture}" "${vendor_fixture}"
    trap - EXIT
    exit "${rc}"
}
trap cleanup EXIT

repo="${fixture}/repo"
scripts="${repo}/Producer/scripts"
patch_root="${repo}/Producer/core-patches"
vendor_root="${repo}/Producer/Sources/CTLSProducerCore"
mkdir -p "${scripts}" "${patch_root}" "${vendor_root}"
cp "${SCRIPT_DIR}/../verify-core-version.sh" "${scripts}/verify-core-version.sh"

patch_rel="Producer/core-patches/fixture.patch"
patch_path="${repo}/${patch_rel}"
printf '%s\n' 'fixture integration patch' > "${patch_path}"
patch_sha="$(shasum -a 256 "${patch_path}" | awk '{print $1}')"
vendor_file="${vendor_root}/fixture.c"
printf '%s\n' 'fixture vendored Core file' > "${vendor_file}"
vendor_file_sha="$(shasum -a 256 "${vendor_file}" | awk '{print $1}')"
printf '%s  %s\n' "${vendor_file_sha}" 'Producer/Sources/CTLSProducerCore/fixture.c' \
    > "${repo}/Producer/CORE_VENDOR_SHA256SUMS"

non_patch_rel="Producer/core-patches/fixture.txt"
non_patch_path="${repo}/${non_patch_rel}"
printf '%s\n' 'fixture non-patch file' > "${non_patch_path}"
non_patch_sha="$(shasum -a 256 "${non_patch_path}" | awk '{print $1}')"
non_regular_patch_rel="Producer/core-patches/directory.patch"
mkdir "${repo}/${non_regular_patch_rel}"
parent_patch_rel="Producer/core-patches/nested-link/parent.patch"
parent_patch_root="${patch_root}/nested-real"
mkdir "${parent_patch_root}"
parent_patch_path="${parent_patch_root}/parent.patch"
printf '%s\n' 'fixture patch below a symlinked parent' > "${parent_patch_path}"
parent_patch_sha="$(shasum -a 256 "${parent_patch_path}" | awk '{print $1}')"
ln -s "${parent_patch_root}" "${patch_root}/nested-link"

vendor_log="${fixture}/vendor-args.log"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ -n "${VENDOR_CALL_LOG:-}" ]]; then' \
    '    if [[ "$#" -eq 0 ]]; then : > "${VENDOR_CALL_LOG}"; else printf "%s\\n" "$@" > "${VENDOR_CALL_LOG}"; fi' \
    'fi' \
    'if [[ "${VENDOR_STUB_MODE:-pass}" == "fail" ]]; then echo "FAIL: fixture vendor verifier"; exit 17; fi' \
    'echo "OK: fixture vendor verifier"' \
    > "${scripts}/verify-core-vendor.sh"
chmod +x "${scripts}/verify-core-version.sh" "${scripts}/verify-core-vendor.sh"

write_registry() {
    local status="$1"
    local patch_mode="${2:-normal}"
    {
        printf '%s\n' '# Vendored Producer Core provenance'
        printf '%s\n' "status: ${status}"
        printf '%s\n' 'component: ve-tls-c-sdk'
        printf '%s\n' 'upstream_core_tag: v0.3.2'
        printf '%s\n' 'upstream_core_full_sha: 1d41ec4edb850ee7dd0b7f63c49738d6a9669c21'
        printf '%s\n' 'vendor_manifest: Producer/CORE_VENDOR_SHA256SUMS'
        if [[ "${status}" == "UNRELEASED_INTEGRATION" ]]; then
            case "${patch_mode}" in
                missingpatch)
                    printf '%s\n' "integration_patch_sha256: ${patch_sha}"
                    ;;
                missinghash)
                    printf '%s\n' "integration_patch: ${patch_rel}"
                    ;;
                emptyhash)
                    printf '%s\n' "integration_patch: ${patch_rel}"
                    printf '%s\n' 'integration_patch_sha256:'
                    ;;
                invalidpath)
                    printf '%s\n' 'integration_patch: Producer/core-patches/../outside.patch'
                    printf '%s\n' "integration_patch_sha256: ${patch_sha}"
                    ;;
                absolute)
                    printf '%s\n' 'integration_patch: /tmp/tls-core-version-absolute.patch'
                    printf '%s\n' "integration_patch_sha256: ${patch_sha}"
                    ;;
                nonpatch)
                    printf '%s\n' "integration_patch: ${non_patch_rel}"
                    printf '%s\n' "integration_patch_sha256: ${non_patch_sha}"
                    ;;
                nonregular)
                    printf '%s\n' "integration_patch: ${non_regular_patch_rel}"
                    printf '%s\n' "integration_patch_sha256: ${patch_sha}"
                    ;;
                parentsymlink)
                    printf '%s\n' "integration_patch: ${parent_patch_rel}"
                    printf '%s\n' "integration_patch_sha256: ${parent_patch_sha}"
                    ;;
                symlink)
                    printf '%s\n' 'integration_patch: Producer/core-patches/link.patch'
                    printf '%s\n' "integration_patch_sha256: ${patch_sha}"
                    ;;
                badhash)
                    printf '%s\n' "integration_patch: ${patch_rel}"
                    printf '%s\n' 'integration_patch_sha256: 0000000000000000000000000000000000000000000000000000000000000000'
                    ;;
                invalidformat)
                    printf '%s\n' "integration_patch: ${patch_rel}"
                    printf '%s\n' 'integration_patch_sha256: E890A04478B14484B7E2C684455BD071E86E9310F3ABF5F425B7C5003C1C4509'
                    ;;
                *)
                    printf '%s\n' "integration_patch: ${patch_rel}"
                    printf '%s\n' "integration_patch_sha256: ${patch_sha}"
                    ;;
            esac
        fi
        printf '%s\n' 'vendor_overlays: include/ve_tls_export.h,third_party/lz4/lz4.c'
        printf '%s\n' 'vendor_additions: include/CTLSProducerCore.h,core/ve_tls_iosp_version.c'
    } > "${repo}/Producer/CORE_VERSION"
}

case_count=0
stub_mode=""

run_fixture() {
    local name="$1"
    local expected_rc="$2"
    local expected_pattern="$3"
    shift 3
    local output
    local rc
    : > "${vendor_log}"
    if output="$(VENDOR_CALL_LOG="${vendor_log}" VENDOR_STUB_MODE="${stub_mode}" \
        "${scripts}/verify-core-version.sh" "$@" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "${output}" > "${fixture}/${name}.log"
    if [[ "${rc}" -ne "${expected_rc}" ]] || ! grep -Eq "${expected_pattern}" <<< "${output}"; then
        echo "FAIL: ${name} expected exit=${expected_rc} pattern=${expected_pattern}, got exit=${rc}"
        cat "${fixture}/${name}.log"
        exit 1
    fi
    case_count=$((case_count + 1))
    echo "OK: ${name}"
}

write_registry INTEGRATED
run_fixture integrated-release 0 'OK: Core integration registry' --release
run_fixture integrated-integration 0 'OK: Core integration registry' --integration

write_registry UNRELEASED_INTEGRATION
run_fixture unreleased-integration 0 'OK: Core integration registry' --integration
if [[ -s "${vendor_log}" ]]; then
    echo 'FAIL: integration mode passed arguments to verify-core-vendor.sh'
    exit 1
fi
run_fixture unreleased-release 1 '^BLOCKED: unreleased Core integration' --release
run_fixture default-release 1 '^BLOCKED: unreleased Core integration'

write_registry UNKNOWN
run_fixture unknown-status 1 'unsupported Core integration status'

write_registry INTEGRATED
printf '%s\n' 'component: duplicate' >> "${repo}/Producer/CORE_VERSION"
run_fixture duplicate-field 1 'expected exactly one component field'

write_registry UNRELEASED_INTEGRATION
printf '%s\n' "integration_patch: ${patch_rel}" >> "${repo}/Producer/CORE_VERSION"
run_fixture duplicate-integration-field 1 'integration patch fields must not be duplicated' --integration

write_registry UNRELEASED_INTEGRATION missingpatch
run_fixture missing-patch 1 'requires exactly one integration_patch' --integration

write_registry UNRELEASED_INTEGRATION missinghash
run_fixture missing-hash 1 'requires exactly one integration_patch' --integration

write_registry UNRELEASED_INTEGRATION emptyhash
run_fixture empty-hash 1 'integration_patch_sha256 must not be empty' --integration

write_registry UNRELEASED_INTEGRATION
printf '%s\n' "integration_patch_sha256: ${patch_sha}" >> "${repo}/Producer/CORE_VERSION"
run_fixture duplicate-integration-hash 1 'integration patch fields must not be duplicated' --integration

write_registry UNRELEASED_INTEGRATION invalidpath
run_fixture invalid-path 1 'unsafe path' --integration

write_registry UNRELEASED_INTEGRATION absolute
run_fixture absolute-path 1 'must be under Producer/core-patches' --integration

write_registry UNRELEASED_INTEGRATION nonpatch
run_fixture non-patch-extension 1 'must name a \.patch file' --integration

write_registry UNRELEASED_INTEGRATION nonregular
run_fixture non-regular-patch 1 'existing regular non-symlink file' --integration

write_registry UNRELEASED_INTEGRATION parentsymlink
run_fixture symlink-patch-parent 1 'parent directory must not be a symlink' --integration
rm "${patch_root}/nested-link"

ln -s "${patch_path}" "${patch_root}/link.patch"
write_registry UNRELEASED_INTEGRATION symlink
run_fixture symlink-patch 1 'regular non-symlink' --integration
rm "${patch_root}/link.patch"

write_registry UNRELEASED_INTEGRATION badhash
run_fixture invalid-hash 1 'checksum does not match registry' --integration

write_registry UNRELEASED_INTEGRATION invalidformat
run_fixture invalid-hash-format 1 'must be a 64-character lowercase SHA-256' --integration

write_registry UNRELEASED_INTEGRATION
stub_mode="fail"
run_fixture vendor-failure 17 'verify-core-vendor.sh failed \(exit 17\)' --integration
stub_mode=""

run_fixture bad-cli-argument 2 '^usage:' --bad
run_fixture extra-cli-argument 2 '^usage:' --integration extra

actual_vendor_repo="${vendor_fixture}/repo"
actual_vendor_scripts="${actual_vendor_repo}/Producer/scripts"
actual_vendor_patch_root="${actual_vendor_repo}/Producer/core-patches"
actual_vendor_root="${actual_vendor_repo}/Producer/Sources/CTLSProducerCore"
mkdir -p "${actual_vendor_scripts}" "${actual_vendor_patch_root}" "${actual_vendor_root}"
cp "${SCRIPT_DIR}/../verify-core-version.sh" "${actual_vendor_scripts}/verify-core-version.sh"
cp "${SCRIPT_DIR}/../verify-core-vendor.sh" "${actual_vendor_scripts}/verify-core-vendor.sh"
chmod +x "${actual_vendor_scripts}/verify-core-version.sh" \
    "${actual_vendor_scripts}/verify-core-vendor.sh"

actual_vendor_patch_rel="Producer/core-patches/fixture.patch"
actual_vendor_patch_path="${actual_vendor_repo}/${actual_vendor_patch_rel}"
printf '%s\n' 'actual vendor fixture integration patch' > "${actual_vendor_patch_path}"
actual_vendor_patch_sha="$(shasum -a 256 "${actual_vendor_patch_path}" | awk '{print $1}')"
actual_vendor_file_rel="Producer/Sources/CTLSProducerCore/fixture.c"
actual_vendor_file_path="${actual_vendor_repo}/${actual_vendor_file_rel}"
printf '%s\n' 'actual vendor fixture Core file' > "${actual_vendor_file_path}"
actual_vendor_file_sha="$(shasum -a 256 "${actual_vendor_file_path}" | awk '{print $1}')"
actual_vendor_manifest="${actual_vendor_repo}/Producer/CORE_VENDOR_SHA256SUMS"

write_actual_vendor_registry() {
    {
        printf '%s\n' '# Vendored Producer Core provenance'
        printf '%s\n' 'status: UNRELEASED_INTEGRATION'
        printf '%s\n' 'component: ve-tls-c-sdk'
        printf '%s\n' 'upstream_core_tag: v0.3.2'
        printf '%s\n' 'upstream_core_full_sha: 1d41ec4edb850ee7dd0b7f63c49738d6a9669c21'
        printf '%s\n' 'vendor_manifest: Producer/CORE_VENDOR_SHA256SUMS'
        printf '%s\n' "integration_patch: ${actual_vendor_patch_rel}"
        printf '%s\n' "integration_patch_sha256: ${actual_vendor_patch_sha}"
        printf '%s\n' 'vendor_overlays: include/ve_tls_export.h,third_party/lz4/lz4.c'
        printf '%s\n' 'vendor_additions: include/CTLSProducerCore.h,core/ve_tls_iosp_version.c'
    } > "${actual_vendor_repo}/Producer/CORE_VERSION"
}

run_actual_vendor_fixture() {
    local name="$1"
    local expected_rc="$2"
    local expected_pattern="$3"
    local secondary_pattern="${4:-}"
    local source_root="${5:-}"
    local output
    local rc
    if output="$(VE_TLS_CORE_SOURCE_ROOT="${source_root}" \
        "${actual_vendor_scripts}/verify-core-version.sh" --integration 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "${output}" > "${vendor_fixture}/${name}.log"
    if [[ "${rc}" -ne "${expected_rc}" ]] || \
       ! grep -Eq "${expected_pattern}" <<< "${output}"; then
        echo "FAIL: ${name} expected exit=${expected_rc} pattern=${expected_pattern}, got exit=${rc}"
        cat "${vendor_fixture}/${name}.log"
        exit 1
    fi
    if [[ -n "${secondary_pattern}" ]] && \
       ! grep -Eq "${secondary_pattern}" <<< "${output}"; then
        echo "FAIL: ${name} missing secondary pattern=${secondary_pattern}"
        cat "${vendor_fixture}/${name}.log"
        exit 1
    fi
    case_count=$((case_count + 1))
    echo "OK: ${name}"
}

write_actual_vendor_registry
printf '%s  %s\n' \
    '0000000000000000000000000000000000000000000000000000000000000000' \
    "${actual_vendor_file_rel}" > "${actual_vendor_manifest}"
run_actual_vendor_fixture actual-vendor-checksum-failure 1 \
    'verify-core-vendor.sh failed \(exit 1\)' 'FAILED'

write_actual_vendor_registry
printf '%s  %s\n' "${actual_vendor_file_sha}" "${actual_vendor_file_rel}" \
    > "${actual_vendor_manifest}"
printf '%s\n' 'unregistered actual vendor file' \
    > "${actual_vendor_root}/extra.c"
run_actual_vendor_fixture actual-vendor-file-set-failure 1 \
    'verify-core-vendor.sh failed \(exit 1\)' 'vendor file set differs from the checksum manifest'
rm "${actual_vendor_root}/extra.c"

actual_source_root="${vendor_fixture}/source"
mkdir -p "${actual_source_root}"
git -C "${actual_source_root}" init -q
printf '%s\n' 'source root mismatch fixture' > "${actual_source_root}/fixture.txt"
git -C "${actual_source_root}" add fixture.txt
git -c user.name='TLS fixture' -c user.email='tls-fixture@example.invalid' \
    -C "${actual_source_root}" commit -qm 'fixture source root'
write_actual_vendor_registry
printf '%s  %s\n' "${actual_vendor_file_sha}" "${actual_vendor_file_rel}" \
    > "${actual_vendor_manifest}"
run_actual_vendor_fixture source-root-mismatch 1 \
    'verify-core-vendor.sh failed \(exit 1\)' \
    'source checkout SHA .* does not match' "${actual_source_root}"

actual_output=""
actual_rc=0
if actual_output="$(VE_TLS_CORE_SOURCE_ROOT="" "${SCRIPT_DIR}/../verify-core-version.sh" --integration 2>&1)"; then
    actual_rc=0
else
    actual_rc=$?
fi
printf '%s\n' "${actual_output}" > "${fixture}/actual-worktree-integration.log"
if [[ "${actual_rc}" -ne 0 ]] ||
   ! grep -q 'OK: committed C Core vendor checksums and file set verified' <<< "${actual_output}" ||
   ! grep -q 'OK: Core integration registry is complete and well formed' <<< "${actual_output}"; then
    echo "FAIL: actual worktree integration verification expected pass, got exit=${actual_rc}"
    cat "${fixture}/actual-worktree-integration.log"
    exit 1
fi
case_count=$((case_count + 1))
echo 'OK: actual worktree integration verification'

echo "OK: verify-core-version tests (${case_count} cases)"
