#!/usr/bin/env bash
#
# Verify that the vendored Producer Core is registered as integrated.
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

read_field() {
    local key="$1"
    local count
    local value
    count="$(grep -Ec "^${key}:" "${CORE_VERSION}" || true)"
    if [[ "${count}" != "1" ]]; then
        echo "FAIL: expected exactly one ${key} field in ${CORE_VERSION}"
        exit 1
    fi
    value="$(grep -E "^${key}:" "${CORE_VERSION}" | sed "s/^${key}:[[:space:]]*//")"
    if [[ -z "${value}" ]]; then
        echo "FAIL: ${key} must not be empty"
        exit 1
    fi
    printf '%s' "${value}"
}

status="$(read_field status)"
component="$(read_field component)"
core_tag="$(read_field upstream_core_tag)"
core_sha="$(read_field upstream_core_full_sha)"
manifest="$(read_field vendor_manifest)"
overlays="$(read_field vendor_overlays)"
additions="$(read_field vendor_additions)"

echo "CORE_VERSION status: ${status}"

if [[ "${status}" == BLOCKED* ]]; then
    echo "FAIL: Real Core integration gate not met (status=${status})."
    echo "Pending fields:"
    grep -nE '^[a-z_]+:.*<pending>' "${CORE_VERSION}" || true
    exit 1
fi

if [[ "${status}" != "INTEGRATED" ]]; then
    echo "FAIL: unsupported Core integration status: ${status}"
    exit 1
fi
if [[ "${component}" != "ve-tls-c-sdk" ]]; then
    echo "FAIL: unexpected Core component: ${component}"
    exit 1
fi
if [[ ! "${core_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "FAIL: upstream_core_tag is not a release tag: ${core_tag}"
    exit 1
fi
if [[ ! "${core_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "FAIL: upstream_core_full_sha must be a full lowercase Git SHA"
    exit 1
fi
if [[ "${manifest}" != "Producer/CORE_VENDOR_SHA256SUMS" ]] || \
   [[ ! -f "${REPO_ROOT}/${manifest}" ]]; then
    echo "FAIL: registered vendor manifest is missing or unexpected: ${manifest}"
    exit 1
fi
if [[ "${overlays}" != "include/ve_tls_export.h,third_party/lz4/lz4.c" ]]; then
    echo "FAIL: the registered Apple packaging overlays changed"
    exit 1
fi
if [[ "${additions}" != "include/CTLSProducerCore.h,core/ve_tls_iosp_version.c" ]]; then
    echo "FAIL: the registered Apple wrapper files changed"
    exit 1
fi

echo "OK: Core integration registry is complete and well formed."
