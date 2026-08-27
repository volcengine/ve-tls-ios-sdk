#!/usr/bin/env bash
#
# verify-public-symbols.sh — check a built product for leaked C symbols.
#
# On macOS, uses nm(1) to inspect a built VolcengineTLSProducer product:
#   - no exported ve_tls_* symbols outside the allowlist
#   - (Swift public API C-type exposure requires source review /
#      swift-api-digester; this script checks the symbol table only)
#
# Without nm, without a built product, or without a symbol allowlist, SKIPs
# with a clear message (never fakes green).
#
# Usage: verify-public-symbols.sh [path-to-built-product]
#
# Environment: macOS with a built .framework/.a (from swift build / xcodebuild).
# Evidence level: symbol-table inspection only; ≠ runtime/device verification.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CORE_VERSION="${REPO_ROOT}/Producer/CORE_VERSION"

echo "== verify-public-symbols =="

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: symbol verification requires macOS (nm on Mach-O); current OS is $(uname -s)."
    exit 0
fi

if ! command -v nm >/dev/null 2>&1; then
    echo "SKIP: nm not found."
    exit 0
fi

# The allowlist comes from CORE_VERSION. Without it we cannot judge a leak.
if [[ ! -f "${CORE_VERSION}" ]]; then
    echo "SKIP: ${CORE_VERSION} not found; cannot read symbol_allowlist."
    exit 0
fi
allowlist="$(grep -E '^symbol_allowlist:' "${CORE_VERSION}" | head -n1 | sed 's/^symbol_allowlist:[[:space:]]*//')"
if [[ "${allowlist}" == '<pending>' || -z "${allowlist}" ]]; then
    echo "SKIP: symbol_allowlist is <pending> in CORE_VERSION; cannot verify without an allowlist."
    exit 0
fi

# Locate a built product: first argument, or auto-discover under .build/.
PRODUCT="${1:-}"
if [[ -z "${PRODUCT}" ]]; then
    PRODUCT="$(find "${REPO_ROOT}/.build" -name 'libVolcengineTLSProducer*' 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${PRODUCT}" || ! -e "${PRODUCT}" ]]; then
    echo "SKIP: no built product found (build first on macOS, or pass a path as \$1)."
    exit 0
fi

echo "Inspecting: ${PRODUCT}"
echo "Allowlist: ${allowlist}"

# Materialize the allowlist (comma/whitespace separated symbol names) for
# exact-substring filtering. Only symbols OUTSIDE the allowlist are leaks.
allowlist_file="$(mktemp)"
printf '%s\n' "${allowlist}" | tr ',; \t' '\n\n\n\n' | sed '/^[[:space:]]*$/d' > "${allowlist_file}"
trap 'rm -f "${allowlist_file}"' EXIT

# Exported (global, defined) symbols matching ve_tls_*, minus the allowlist.
leaked="$(nm -gU "${PRODUCT}" 2>/dev/null | grep -E 've_tls_' | { [[ -s "${allowlist_file}" ]] && grep -vFf "${allowlist_file}" || cat; } || true)"
if [[ -n "${leaked}" ]]; then
    echo "FAIL: exported ve_tls_* symbols found outside allowlist:"
    echo "${leaked}"
    exit 1
fi

echo "PASS: no exported ve_tls_* symbols in ${PRODUCT}."
