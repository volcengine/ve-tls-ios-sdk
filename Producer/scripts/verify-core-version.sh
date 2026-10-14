#!/usr/bin/env bash
#
# Verify the vendored Producer Core registry. The default/--release mode
# blocks unreleased integrations; --integration also verifies their registered
# patch and vendor integrity without declaring them ready for release.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CORE_VERSION="${REPO_ROOT}/Producer/CORE_VERSION"
VENDOR_VERIFIER="${SCRIPT_DIR}/verify-core-vendor.sh"

mode="release"
case "$#" in
    0) ;;
    1)
        case "$1" in
            --release) ;;
            --integration) mode="integration" ;;
            *)
                echo "usage: $0 [--release|--integration]" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "usage: $0 [--release|--integration]" >&2
        exit 2
        ;;
esac

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
        echo "FAIL: expected exactly one ${key} field in ${CORE_VERSION}" >&2
        exit 1
    fi
    value="$(grep -E "^${key}:" "${CORE_VERSION}" | sed "s/^${key}:[[:space:]]*//")"
    if [[ -z "${value}" ]]; then
        echo "FAIL: ${key} must not be empty" >&2
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

integration_patch_count="$(grep -Ec '^integration_patch:' "${CORE_VERSION}" || true)"
integration_patch_sha_count="$(grep -Ec '^integration_patch_sha256:' "${CORE_VERSION}" || true)"
if [[ "${integration_patch_count}" -gt 1 ]] || [[ "${integration_patch_sha_count}" -gt 1 ]]; then
    echo "FAIL: integration patch fields must not be duplicated"
    exit 1
fi

echo "CORE_VERSION status: ${status}"

if [[ "${status}" == BLOCKED* ]]; then
    echo "FAIL: Real Core integration gate not met (status=${status})."
    echo "Pending fields:"
    grep -nE '^[a-z_]+:.*<pending>' "${CORE_VERSION}" || true
    exit 1
fi

if [[ "${status}" == "UNRELEASED_INTEGRATION" ]] && [[ "${mode}" == "release" ]]; then
    echo "BLOCKED: unreleased Core integration is not eligible for release verification"
    echo "FAIL: release verification is blocked until Core status is INTEGRATED"
    exit 1
fi

if [[ "${status}" != "INTEGRATED" ]] && [[ "${status}" != "UNRELEASED_INTEGRATION" ]]; then
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

if [[ "${status}" == "UNRELEASED_INTEGRATION" ]]; then
    if [[ "${integration_patch_count}" != "1" ]] || [[ "${integration_patch_sha_count}" != "1" ]]; then
        echo "FAIL: UNRELEASED_INTEGRATION requires exactly one integration_patch and integration_patch_sha256 field"
        exit 1
    fi

    integration_patch="$(read_field integration_patch)"
    integration_patch_sha="$(read_field integration_patch_sha256)"

    case "/${integration_patch}/" in
        /Producer/core-patches/*) ;;
        *)
            echo "FAIL: integration_patch must be under Producer/core-patches: ${integration_patch}"
            exit 1
            ;;
    esac
    case "/${integration_patch}/" in
        *//*|*/./*|*/../*)
            echo "FAIL: integration_patch contains an unsafe path: ${integration_patch}"
            exit 1
            ;;
    esac
    case "${integration_patch}" in
        *.patch) ;;
        *)
            echo "FAIL: integration_patch must name a .patch file: ${integration_patch}"
            exit 1
            ;;
    esac

    integration_patch_path="${REPO_ROOT}/${integration_patch}"
    if [[ -L "${REPO_ROOT}/Producer" ]] || [[ -L "${REPO_ROOT}/Producer/core-patches" ]]; then
        echo "FAIL: integration_patch parent directory must not be a symlink"
        exit 1
    fi
    patch_relative_dir="${integration_patch#Producer/core-patches/}"
    if [[ "${patch_relative_dir}" == */* ]]; then
        patch_relative_dir="${patch_relative_dir%/*}"
        patch_parent="${REPO_ROOT}/Producer/core-patches"
        while [[ -n "${patch_relative_dir}" ]]; do
            patch_component="${patch_relative_dir%%/*}"
            patch_parent="${patch_parent}/${patch_component}"
            if [[ -L "${patch_parent}" ]]; then
                echo "FAIL: integration_patch parent directory must not be a symlink"
                exit 1
            fi
            if [[ "${patch_relative_dir}" == */* ]]; then
                patch_relative_dir="${patch_relative_dir#*/}"
            else
                patch_relative_dir=""
            fi
        done
    fi
    if [[ ! -f "${integration_patch_path}" ]] || [[ -L "${integration_patch_path}" ]]; then
        echo "FAIL: integration_patch must be an existing regular non-symlink file: ${integration_patch}"
        exit 1
    fi

    patch_sha=""
    if ! patch_sha="$(shasum -a 256 "${integration_patch_path}" | awk '{print $1}')"; then
        echo "FAIL: unable to hash integration_patch: ${integration_patch}"
        exit 1
    fi
    if [[ ! "${integration_patch_sha}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "FAIL: integration_patch_sha256 must be a 64-character lowercase SHA-256"
        exit 1
    fi
    if [[ "${patch_sha}" != "${integration_patch_sha}" ]]; then
        echo "FAIL: integration patch checksum does not match registry"
        exit 1
    fi

    if [[ ! -x "${VENDOR_VERIFIER}" ]]; then
        echo "FAIL: vendor verifier is missing or not executable: ${VENDOR_VERIFIER}"
        exit 1
    fi
    if "${VENDOR_VERIFIER}"; then
        :
    else
        vendor_rc=$?
        echo "FAIL: verify-core-vendor.sh failed (exit ${vendor_rc})"
        exit "${vendor_rc}"
    fi
fi

echo "OK: Core integration registry is complete and well formed."
