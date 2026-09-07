#!/usr/bin/env bash
#
# verify-public-symbols.sh — check a final SDK artifact for leaked C symbols.
#
# This check intentionally runs against a linked Mach-O binary or an archive,
# not an arbitrary Swift object. `nm -m` distinguishes an exported `external`
# symbol from a hidden `private external` symbol; undefined references are not
# exports and are ignored. The product's C Core ABI allowlist in
# Producer/CORE_VERSION describes the standalone Core artifact and must not be
# reused as the public SDK allowlist: the C Core and namespaced LZ4 are private
# implementation details of this package.
#
# Usage:
#   verify-public-symbols.sh [path-to-final-product] [path-to-allowlist]
#
# The product may be a Mach-O binary, `.a`, `.framework`, or `.xcframework`.
# The allowlist contains exact symbol names (one per line; `#` comments are
# accepted). No `ve_tls_*`, `VE_TLS_LZ4_*`, or unnamespaced `LZ4_*` symbol is
# permitted by the checked-in default allowlist.
#
# Environment:
#   PUBLIC_SYMBOL_ALLOWLIST=...  override the checked-in exact allowlist.
#   VERIFY_PUBLIC_SYMBOLS_SELF_TEST=1  run portable positive/negative fixtures.
#
# This check inspects symbol tables only; it does not validate runtime behavior
# or App Store packaging.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULT_ALLOWLIST="${SCRIPT_DIR}/public-symbol-allowlist.txt"

find_leaks() {
    local allowlist_path="$1"
    awk -v allowlist_path="${allowlist_path}" '
        BEGIN {
            while ((getline line < allowlist_path) > 0) {
                sub(/\r$/, "", line)
                sub(/[[:space:]]*#.*/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line != "") {
                    allowed[line] = 1
                }
            }
            close(allowlist_path)
        }
        # Undefined references are not exported definitions.
        /undefined/ { next }
        # Hidden Mach-O globals are printed as "private external".
        /private external/ { next }
        # Match `external` as a standalone nm state. `non-external` is an
        # ordinary local definition and must not be mistaken for an export.
        /(^|[[:space:]])external([[:space:]]|$)/ {
            symbol = $NF
            sub(/^_/, "", symbol)
            if (symbol ~ /^(ve_tls_|VE_TLS_LZ4_|LZ4_)/ && !allowed[symbol]) {
                print symbol
            }
        }
    '
}

inspect_product() {
    local product="$1"
    local allowlist_path="$2"
    local nm_output
    local nm_tool="${NM_TOOL:-nm}"
    nm_output="$(mktemp "${TMPDIR:-/tmp}/verify-public-symbols.nm.XXXXXX")"
    if ! "${nm_tool}" -m "${product}" >"${nm_output}" 2>/dev/null; then
        rm -f "${nm_output}"
        return 2
    fi
    find_leaks "${allowlist_path}" <"${nm_output}"
    rm -f "${nm_output}"
}

run_self_test() {
    local allowlist_fixture
    local invalid_product_fixture
    local leaked
    local nm_failure_fixture
    allowlist_fixture="$(mktemp "${TMPDIR:-/tmp}/verify-public-symbols.allowlist.XXXXXX")"
    invalid_product_fixture="$(mktemp "${TMPDIR:-/tmp}/verify-public-symbols.invalid.XXXXXX")"
    nm_failure_fixture="$(mktemp "${TMPDIR:-/tmp}/verify-public-symbols.nm-failure.XXXXXX")"
    trap 'rm -f "${allowlist_fixture:-}" "${invalid_product_fixture:-}" "${nm_failure_fixture:-}"' EXIT
    printf '%s\n' '# exact reviewed exception used only by this fixture' 've_tls_allowed' > "${allowlist_fixture}"

    # Hidden symbols and undefined references must not be reported.
    leaked="$(printf '%s\n' \
        '000 (__TEXT,__text) private external _ve_tls_hidden' \
        '                 (undefined) external _ve_tls_dependency' \
        | find_leaks "${allowlist_fixture}")"
    if [[ -n "${leaked}" ]]; then
        echo "FAIL: self-test reported hidden/undefined symbols:"
        echo "${leaked}"
        return 1
    fi

    # Exact allowlist entries are accepted, while Core and both LZ4 naming forms fail.
    leaked="$(printf '%s\n' \
        '000 (__TEXT,__text) external _ve_tls_allowed' \
        '000 (__TEXT,__text) external _ve_tls_leak' \
        '000 (__TEXT,__text) external _VE_TLS_LZ4_leak' \
        '000 (__TEXT,__text) external _LZ4_leak' \
        | find_leaks "${allowlist_fixture}")"
    expected=$'ve_tls_leak\nVE_TLS_LZ4_leak\nLZ4_leak'
    if [[ "${leaked}" != "${expected}" ]]; then
        echo "FAIL: self-test did not reject the expected exported symbols."
        echo "Expected:"
        echo "${expected}"
        echo "Actual:"
        echo "${leaked}"
        return 1
    fi

    printf '%s\n' '#!/bin/sh' 'exit 42' > "${nm_failure_fixture}"
    chmod +x "${nm_failure_fixture}"
    if NM_TOOL="${nm_failure_fixture}" inspect_product "${invalid_product_fixture}" "${allowlist_fixture}" >/dev/null 2>&1; then
        echo "FAIL: self-test accepted an artifact after nm failed."
        return 1
    fi

    echo "OK: public-symbol self-test (hidden/undefined/allowlisted/rejected/nm-failure fixtures)."
}

if [[ "${VERIFY_PUBLIC_SYMBOLS_SELF_TEST:-0}" == "1" ]]; then
    run_self_test
    exit $?
fi

echo "== verify-public-symbols =="

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: symbol verification requires macOS (nm -m on Mach-O); current OS is $(uname -s)."
    exit 0
fi

nm_tool="${NM_TOOL:-nm}"
if ! command -v "${nm_tool}" >/dev/null 2>&1; then
    echo "SKIP: nm tool not found: ${nm_tool}."
    exit 0
fi

allowlist="${2:-${PUBLIC_SYMBOL_ALLOWLIST:-${DEFAULT_ALLOWLIST}}}"
if [[ ! -f "${allowlist}" ]]; then
    echo "FAIL: exact public-symbol allowlist not found: ${allowlist}"
    exit 1
fi

# Locate a final product: first argument, or auto-discover a SwiftPM archive.
product="${1:-}"
if [[ -z "${product}" ]]; then
    product="$(find "${REPO_ROOT}/.build" -type f \( \
        -name 'libVolcengineTLSProducer.a' -o \
        -name 'VolcengineTLSProducer' \
    \) 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${product}" || ! -e "${product}" ]]; then
    echo "SKIP: no final SDK product found (build first or pass a path as \$1)."
    exit 0
fi

if [[ -d "${product}" ]]; then
    case "${product}" in
        *.framework)
            binary_name="$(basename "${product}" .framework)"
            product="${product}/${binary_name}"
            ;;
        *.xcframework)
            binary_name="$(basename "${product}" .xcframework)"
            product="$(find "${product}" -type f -name "${binary_name}" | head -n1 || true)"
            ;;
        *)
            echo "FAIL: unsupported product directory (expected .framework/.xcframework): ${product}"
            exit 1
            ;;
    esac
fi

if [[ -z "${product}" || ! -f "${product}" ]]; then
    echo "FAIL: final SDK binary could not be resolved from the supplied product."
    exit 1
fi

echo "Inspecting final product: ${product}"
echo "Exact public-symbol allowlist: ${allowlist}"

# Do not use `nm -gU`: it also reports private external definitions on Darwin,
# which made the former script accept the wrong object set and could not prove
# that hidden symbols stayed hidden in the final linked artifact.
if ! leaked="$(inspect_product "${product}" "${allowlist}")"; then
    echo "FAIL: nm could not inspect the supplied SDK artifact: ${product}"
    exit 1
fi
if [[ -n "${leaked}" ]]; then
    echo "FAIL: exported C symbols found outside the reviewed public allowlist:"
    echo "${leaked}"
    exit 1
fi

echo "OK: no exported ve_tls_*/VE_TLS_LZ4_*/LZ4_* symbols in ${product}."
