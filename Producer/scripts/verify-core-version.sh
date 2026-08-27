#!/usr/bin/env bash
#
# verify-core-version.sh — C Core integration gate.
#
# Parses Producer/CORE_VERSION. While status is BLOCKED, this script FAILS on
# purpose: the real C Core has not passed the release gate, so no persistent/
# retry/ACK/real-send/Beta claims may be made. This is an intentional red gate.
#
# Environment: any (Linux dev machine OK). Read-only.
# Evidence level: script PASS ≠ device/Beta pass; it only checks the registry.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CORE_VERSION="${REPO_ROOT}/Producer/CORE_VERSION"

echo "== verify-core-version =="

if [[ ! -f "${CORE_VERSION}" ]]; then
    echo "FAIL: ${CORE_VERSION} not found"
    exit 1
fi

status="$(grep -E '^status:' "${CORE_VERSION}" | head -n1 | sed 's/^status:[[:space:]]*//')"
echo "CORE_VERSION status: ${status}"

if [[ "${status}" == BLOCKED* ]]; then
    echo "FAIL: Real Core integration gate not met (status=${status})."
    echo "Pending fields:"
    grep -nE '^[a-z_]+:.*<pending>' "${CORE_VERSION}" || true
    exit 1
fi

echo "PASS: Core integration gate met."
