#!/usr/bin/env bash
#
# Verify the committed C Core snapshot used by the Producer package.
#
# The checksum gate always runs. Set VE_TLS_CORE_SOURCE_ROOT to a checkout at
# the registered commit to additionally compare every non-overlay source file.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REGISTRY="${REPO_ROOT}/Producer/CORE_VERSION"
MANIFEST_REL="Producer/CORE_VENDOR_SHA256SUMS"
MANIFEST="${REPO_ROOT}/${MANIFEST_REL}"
VENDOR_REL="Producer/Sources/CTLSProducerCore"
VENDOR_ROOT="${REPO_ROOT}/${VENDOR_REL}"

echo "== verify-core-vendor =="

if [[ ! -f "${MANIFEST}" ]]; then
    echo "FAIL: vendor checksum manifest is missing: ${MANIFEST_REL}"
    exit 1
fi

task_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/verify-core-vendor.XXXXXX")"
cleanup() {
    rm -f "${task_temp_dir}/actual-files" "${task_temp_dir}/manifest-files"
    rmdir "${task_temp_dir}" 2>/dev/null || true
}
trap cleanup EXIT

(cd "${REPO_ROOT}" && shasum -a 256 -c "${MANIFEST_REL}")
find "${VENDOR_ROOT}" -type f | sed "s#^${REPO_ROOT}/##" | LC_ALL=C sort \
    > "${task_temp_dir}/actual-files"
awk '{print $2}' "${MANIFEST}" | LC_ALL=C sort \
    > "${task_temp_dir}/manifest-files"
if ! diff -u "${task_temp_dir}/manifest-files" "${task_temp_dir}/actual-files"; then
    echo "FAIL: vendor file set differs from the checksum manifest"
    exit 1
fi

core_source_root="${VE_TLS_CORE_SOURCE_ROOT:-}"
if [[ -z "${core_source_root}" ]]; then
    echo "SKIP: set VE_TLS_CORE_SOURCE_ROOT for an exact source-checkout comparison."
    echo "OK: committed C Core vendor checksums and file set verified."
    exit 0
fi
if ! git -C "${core_source_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "FAIL: VE_TLS_CORE_SOURCE_ROOT is not a Git checkout"
    exit 1
fi

registered_sha="$(grep -E '^upstream_core_full_sha:' "${REGISTRY}" | sed 's/^upstream_core_full_sha:[[:space:]]*//')"
actual_sha="$(git -C "${core_source_root}" rev-parse HEAD)"
if [[ "${actual_sha}" != "${registered_sha}" ]]; then
    echo "FAIL: source checkout SHA ${actual_sha} does not match ${registered_sha}"
    exit 1
fi

while IFS='|' read -r source_path vendor_path; do
    [[ -n "${source_path}" ]] || continue
    if [[ ! -f "${core_source_root}/${source_path}" ]] || \
       [[ ! -f "${VENDOR_ROOT}/${vendor_path}" ]]; then
        echo "FAIL: missing mapped Core file: ${source_path} -> ${vendor_path}"
        exit 1
    fi
    if ! cmp -s "${core_source_root}/${source_path}" "${VENDOR_ROOT}/${vendor_path}"; then
        echo "FAIL: vendored Core file differs: ${source_path} -> ${vendor_path}"
        exit 1
    fi
done <<'EOF'
core/include/ve_tls_alloc.h|include/ve_tls_alloc.h
core/include/ve_tls_compress.h|include/ve_tls_compress.h
core/include/ve_tls_env.h|include/ve_tls_env.h
core/include/ve_tls_error.h|include/ve_tls_error.h
core/include/ve_tls_hash.h|include/ve_tls_hash.h
core/include/ve_tls_http.h|include/ve_tls_http.h
core/include/ve_tls_producer.h|include/ve_tls_producer.h
core/include/ve_tls_proto.h|include/ve_tls_proto.h
core/include/ve_tls_retry.h|include/ve_tls_retry.h
core/include/ve_tls_sign.h|include/ve_tls_sign.h
core/include/ve_tls_version.h|include/ve_tls_version.h
adapters/include/ve_tls_platform.h|include/ve_tls_platform.h
adapters/src/ve_tls_platform_pthread.c|adapters/ve_tls_platform_pthread.c
core/src/ve_tls_alloc.c|core/src/ve_tls_alloc.c
core/src/ve_tls_compress.c|core/src/ve_tls_compress.c
core/src/ve_tls_error.c|core/src/ve_tls_error.c
core/src/ve_tls_hash.c|core/src/ve_tls_hash.c
core/src/ve_tls_http_types.c|core/src/ve_tls_http_types.c
core/src/ve_tls_producer.c|core/src/ve_tls_producer.c
core/src/ve_tls_proto.c|core/src/ve_tls_proto.c
core/src/ve_tls_retry.c|core/src/ve_tls_retry.c
core/src/ve_tls_sign.c|core/src/ve_tls_sign.c
core/src/producer/ve_tls_checkpoint.c|core/src/producer/ve_tls_checkpoint.c
core/src/producer/ve_tls_checkpoint.h|core/src/producer/ve_tls_checkpoint.h
core/src/producer/ve_tls_env.c|core/src/producer/ve_tls_env.c
core/src/producer/ve_tls_lease.c|core/src/producer/ve_tls_lease.c
core/src/producer/ve_tls_lease.h|core/src/producer/ve_tls_lease.h
core/src/producer/ve_tls_persistent.c|core/src/producer/ve_tls_persistent.c
core/src/producer/ve_tls_persistent.h|core/src/producer/ve_tls_persistent.h
core/src/producer/ve_tls_persistent_format.c|core/src/producer/ve_tls_persistent_format.c
core/src/producer/ve_tls_persistent_format.h|core/src/producer/ve_tls_persistent_format.h
core/src/producer/ve_tls_pool.c|core/src/producer/ve_tls_pool.c
core/src/producer/ve_tls_pool.h|core/src/producer/ve_tls_pool.h
core/src/producer/ve_tls_producer_builder.c|core/src/producer/ve_tls_producer_builder.c
core/src/producer/ve_tls_producer_common.c|core/src/producer/ve_tls_producer_common.c
core/src/producer/ve_tls_producer_config.c|core/src/producer/ve_tls_producer_config.c
core/src/producer/ve_tls_producer_internal.h|core/src/producer/ve_tls_producer_internal.h
core/src/producer/ve_tls_producer_manager.c|core/src/producer/ve_tls_producer_manager.c
core/src/producer/ve_tls_producer_queue.c|core/src/producer/ve_tls_producer_queue.c
core/src/producer/ve_tls_producer_sender.c|core/src/producer/ve_tls_producer_sender.c
core/src/producer/ve_tls_segment_store.c|core/src/producer/ve_tls_segment_store.c
core/src/producer/ve_tls_segment_store.h|core/src/producer/ve_tls_segment_store.h
core/src/producer/ve_tls_snapshot.c|core/src/producer/ve_tls_snapshot.c
core/src/producer/ve_tls_snapshot.h|core/src/producer/ve_tls_snapshot.h
third_party/lz4/lz4.h|third_party/lz4/lz4.h
third_party/lz4/lz4_namespace.h|third_party/lz4/lz4_namespace.h
EOF

echo "OK: committed vendor and exact C Core checkout match outside registered overlays."
