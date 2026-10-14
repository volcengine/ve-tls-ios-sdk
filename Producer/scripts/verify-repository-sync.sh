#!/usr/bin/env bash
#
# Verify that a public synchronization commit preserves the internal commit
# ancestry and the complete internal Git tree. This script is deliberately
# read-only: it resolves objects and inspects ancestry/tree IDs in the caller's
# current repository, without changing refs, the index, or the worktree.
#
# Usage:
#   bash verify-repository-sync.sh candidate INTERNAL_REF PUBLIC_BASE SYNC_REF
#   bash verify-repository-sync.sh published INTERNAL_REF PUBLIC_HEAD
#   bash verify-repository-sync.sh tags INTERNAL_REF INTERNAL_TAG_REF PUBLIC_TAG_REF
#
# Exit status:
#   0  all requested invariants pass
#   1  a requested invariant fails
#   2  invalid usage, repository, or object/ref input
#
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage:' \
        '  verify-repository-sync.sh candidate INTERNAL_REF PUBLIC_BASE SYNC_REF' \
        '  verify-repository-sync.sh published INTERNAL_REF PUBLIC_HEAD' \
        '  verify-repository-sync.sh tags INTERNAL_REF INTERNAL_TAG_REF PUBLIC_TAG_REF' >&2
}

usage_error() {
    printf 'ERROR: %s\n' "$1" >&2
    usage
    exit 2
}

if [[ $# -lt 1 ]]; then
    usage_error 'missing mode'
fi

mode="$1"
case "$mode" in
    candidate)
        if [[ $# -ne 4 ]]; then
            usage_error 'candidate requires INTERNAL_REF, PUBLIC_BASE, and SYNC_REF'
        fi
        internal_ref="$2"
        public_base_ref="$3"
        sync_ref="$4"
        ;;
    published)
        if [[ $# -ne 3 ]]; then
            usage_error 'published requires INTERNAL_REF and PUBLIC_HEAD'
        fi
        internal_ref="$2"
        public_head_ref="$3"
        ;;
    tags)
        if [[ $# -ne 4 ]]; then
            usage_error 'tags requires INTERNAL_REF, INTERNAL_TAG_REF, and PUBLIC_TAG_REF'
        fi
        internal_ref="$2"
        internal_tag_ref="$3"
        public_tag_ref="$4"
        ;;
    *)
        usage_error "unknown mode: ${mode}"
        ;;
esac

if [[ -z "$internal_ref" ]]; then
    usage_error 'INTERNAL_REF must not be empty'
fi
if [[ "$mode" == 'candidate' && -z "$public_base_ref" ]]; then
    usage_error 'PUBLIC_BASE must not be empty'
fi
if [[ "$mode" == 'candidate' && -z "$sync_ref" ]]; then
    usage_error 'SYNC_REF must not be empty'
fi
if [[ "$mode" == 'published' && -z "$public_head_ref" ]]; then
    usage_error 'PUBLIC_HEAD must not be empty'
fi
if [[ "$mode" == 'tags' && -z "$internal_tag_ref" ]]; then
    usage_error 'INTERNAL_TAG_REF must not be empty'
fi
if [[ "$mode" == 'tags' && -z "$public_tag_ref" ]]; then
    usage_error 'PUBLIC_TAG_REF must not be empty'
fi

# Do not change directory here. Callers may deliberately invoke this script by
# absolute path while their current directory is the repository being checked.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    usage_error 'current directory is not inside a Git repository'
fi

resolve_commit() {
    local ref="$1"
    local commit_id

    if ! commit_id="$(git rev-parse --verify --quiet --end-of-options "${ref}^{commit}" 2>/dev/null)"; then
        return 2
    fi
    if [[ -z "$commit_id" ]]; then
        return 2
    fi
    printf '%s' "$commit_id"
}

resolve_tree() {
    local commit_id="$1"
    local tree_id

    if ! tree_id="$(git rev-parse --verify --quiet --end-of-options "${commit_id}^{tree}" 2>/dev/null)"; then
        return 2
    fi
    if [[ -z "$tree_id" ]]; then
        return 2
    fi
    printf '%s' "$tree_id"
}

check_ancestor() {
    git merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

if internal_id="$(resolve_commit "$internal_ref")"; then
    :
else
    printf 'ERROR: unresolved INTERNAL_REF: %s\n' "$internal_ref" >&2
    exit 2
fi

if [[ "$mode" == 'candidate' ]]; then
    if public_base_id="$(resolve_commit "$public_base_ref")"; then
        :
    else
        printf 'ERROR: unresolved PUBLIC_BASE: %s\n' "$public_base_ref" >&2
        exit 2
    fi
    if sync_id="$(resolve_commit "$sync_ref")"; then
        :
    else
        printf 'ERROR: unresolved SYNC_REF: %s\n' "$sync_ref" >&2
        exit 2
    fi
elif [[ "$mode" == 'published' ]]; then
    if public_head_id="$(resolve_commit "$public_head_ref")"; then
        :
    else
        printf 'ERROR: unresolved PUBLIC_HEAD: %s\n' "$public_head_ref" >&2
        exit 2
    fi
else
    if internal_tag_id="$(resolve_commit "$internal_tag_ref")"; then
        :
    else
        printf 'ERROR: unresolved INTERNAL_TAG_REF: %s\n' "$internal_tag_ref" >&2
        exit 2
    fi
    if public_tag_id="$(resolve_commit "$public_tag_ref")"; then
        :
    else
        printf 'ERROR: unresolved PUBLIC_TAG_REF: %s\n' "$public_tag_ref" >&2
        exit 2
    fi
fi

if internal_tree="$(resolve_tree "$internal_id")"; then
    :
else
    printf 'ERROR: cannot resolve tree for INTERNAL_REF: %s\n' "$internal_id" >&2
    exit 2
fi

if [[ "$mode" == 'tags' ]]; then
    if internal_tag_tree="$(resolve_tree "$internal_tag_id")"; then
        :
    else
        printf 'ERROR: cannot resolve tree for INTERNAL_TAG_REF: %s\n' "$internal_tag_id" >&2
        exit 2
    fi
    if public_tag_tree="$(resolve_tree "$public_tag_id")"; then
        :
    else
        printf 'ERROR: cannot resolve tree for PUBLIC_TAG_REF: %s\n' "$public_tag_id" >&2
        exit 2
    fi

    printf 'MODE=tags\n'
    printf 'INTERNAL_ID=%s\n' "$internal_id"
    printf 'INTERNAL_TAG_ID=%s\n' "$internal_tag_id"
    printf 'PUBLIC_TAG_ID=%s\n' "$public_tag_id"
    printf 'INTERNAL_TREE=%s\n' "$internal_tree"
    printf 'INTERNAL_TAG_TREE=%s\n' "$internal_tag_tree"
    printf 'PUBLIC_TAG_TREE=%s\n' "$public_tag_tree"

    overall_status=0
    if [[ "$internal_tag_id" == "$internal_id" ]]; then
        printf 'INTERNAL_TAG_MATCH=PASS\n'
    else
        printf 'INTERNAL_TAG_MATCH=FAIL\n'
        overall_status=1
    fi
    if [[ "$public_tag_id" == "$internal_id" ]]; then
        printf 'PUBLIC_TAG_MATCH=PASS\n'
    else
        printf 'PUBLIC_TAG_MATCH=FAIL\n'
        overall_status=1
    fi
    if [[ "$internal_tree" == "$internal_tag_tree" && "$internal_tree" == "$public_tag_tree" ]]; then
        printf 'TREE_EQUAL=PASS\n'
    else
        printf 'TREE_EQUAL=FAIL\n'
        overall_status=1
    fi

    if [[ "$overall_status" -eq 0 ]]; then
        printf 'STATUS=PASS\n'
    else
        printf 'STATUS=FAIL\n'
    fi
    exit "$overall_status"
fi

if [[ "$mode" == 'candidate' ]]; then
    if sync_tree="$(resolve_tree "$sync_id")"; then
        :
    else
        printf 'ERROR: cannot resolve tree for SYNC_REF: %s\n' "$sync_id" >&2
        exit 2
    fi

    printf 'MODE=candidate\n'
    printf 'INTERNAL_ID=%s\n' "$internal_id"
    printf 'PUBLIC_BASE_ID=%s\n' "$public_base_id"
    printf 'SYNC_ID=%s\n' "$sync_id"
    printf 'INTERNAL_TREE=%s\n' "$internal_tree"
    printf 'SYNC_TREE=%s\n' "$sync_tree"

    overall_status=0
    if check_ancestor "$internal_id" "$sync_id"; then
        printf 'INTERNAL_ANCESTOR=PASS\n'
    else
        check_rc=$?
        if [[ "$check_rc" -eq 1 ]]; then
            printf 'INTERNAL_ANCESTOR=FAIL\n'
            overall_status=1
        else
            printf 'ERROR: cannot inspect INTERNAL_ID ancestry\n' >&2
            exit 2
        fi
    fi

    if check_ancestor "$public_base_id" "$sync_id"; then
        printf 'PUBLIC_BASE_ANCESTOR=PASS\n'
    else
        check_rc=$?
        if [[ "$check_rc" -eq 1 ]]; then
            printf 'PUBLIC_BASE_ANCESTOR=FAIL\n'
            overall_status=1
        else
            printf 'ERROR: cannot inspect PUBLIC_BASE_ID ancestry\n' >&2
            exit 2
        fi
    fi

    if [[ "$internal_tree" == "$sync_tree" ]]; then
        printf 'TREE_EQUAL=PASS\n'
    else
        printf 'TREE_EQUAL=FAIL\n'
        overall_status=1
    fi

    if [[ "$overall_status" -eq 0 ]]; then
        printf 'STATUS=PASS\n'
    else
        printf 'STATUS=FAIL\n'
    fi
    exit "$overall_status"
fi

if public_head_tree="$(resolve_tree "$public_head_id")"; then
    :
else
    printf 'ERROR: cannot resolve tree for PUBLIC_HEAD: %s\n' "$public_head_id" >&2
    exit 2
fi

printf 'MODE=published\n'
printf 'INTERNAL_ID=%s\n' "$internal_id"
printf 'PUBLIC_HEAD_ID=%s\n' "$public_head_id"
printf 'INTERNAL_TREE=%s\n' "$internal_tree"
printf 'PUBLIC_HEAD_TREE=%s\n' "$public_head_tree"

overall_status=0
if check_ancestor "$internal_id" "$public_head_id"; then
    printf 'INTERNAL_ANCESTOR=PASS\n'
else
    check_rc=$?
    if [[ "$check_rc" -eq 1 ]]; then
        printf 'INTERNAL_ANCESTOR=FAIL\n'
        overall_status=1
    else
        printf 'ERROR: cannot inspect INTERNAL_ID ancestry\n' >&2
        exit 2
    fi
fi

if [[ "$internal_tree" == "$public_head_tree" ]]; then
    printf 'TREE_EQUAL=PASS\n'
else
    printf 'TREE_EQUAL=FAIL\n'
    overall_status=1
fi

if [[ "$overall_status" -eq 0 ]]; then
    printf 'STATUS=PASS\n'
else
    printf 'STATUS=FAIL\n'
fi
exit "$overall_status"
