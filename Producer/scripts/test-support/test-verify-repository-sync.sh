#!/usr/bin/env bash
# Regression tests for verify-repository-sync.sh.
#
# The fixture is a private synthetic Git repository. commit-tree is used only
# there to model bridge, merge, and squash topology; the verifier itself is
# read-only and no real repository is changed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$(cd "${SCRIPT_DIR}/.." && pwd)/verify-repository-sync.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/tls-repository-sync-test.XXXXXX")"
trap 'rm -rf "${fixture}"' EXIT

# Keep Git configuration local to the synthetic fixture. commit-tree receives
# all identity values through the environment, so no global config is read or
# written and no security hook from a real working repository is bypassed.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='repository-sync-test'
export GIT_AUTHOR_EMAIL='repository-sync-test@example.invalid'
export GIT_COMMITTER_NAME='repository-sync-test'
export GIT_COMMITTER_EMAIL='repository-sync-test@example.invalid'
export GIT_AUTHOR_DATE='2000-01-01T00:00:00Z'
export GIT_COMMITTER_DATE='2000-01-01T00:00:00Z'

git init -q "$fixture"
cd "$fixture"

blob() {
    printf '%s' "$1" | git hash-object -w --stdin
}

tree_with_tool() {
    local source_blob="$1"
    local doc_blob="$2"
    local tool_blob="$3"
    local tool_mode="$4"
    local tool_path="$5"
    {
        printf '100644 blob %s\tsdk-source.c\n' "$source_blob"
        printf '100644 blob %s\trelease-notes.md\n' "$doc_blob"
        printf '%s blob %s\t%s\n' "$tool_mode" "$tool_blob" "$tool_path"
    } | git mktree
}

tree_with_extra_doc() {
    local source_blob="$1"
    local doc_blob="$2"
    local tool_blob="$3"
    local extra_doc_blob="$4"
    {
        printf '100644 blob %s\tsdk-source.c\n' "$source_blob"
        printf '100644 blob %s\trelease-notes.md\n' "$doc_blob"
        printf '100755 blob %s\ttool.sh\n' "$tool_blob"
        printf '100644 blob %s\textra-release-note.md\n' "$extra_doc_blob"
    } | git mktree
}

commit_with_tree() {
    local tree_id="$1"
    local message="$2"
    shift 2
    local parent_args=()
    local parent
    for parent in "$@"; do
        parent_args+=("-p" "$parent")
    done
    if [[ "${#parent_args[@]}" -eq 0 ]]; then
        printf '%s\n' "$message" | git commit-tree "$tree_id"
    else
        printf '%s\n' "$message" | git commit-tree "$tree_id" "${parent_args[@]}"
    fi
}

annotated_tag() {
    local commit_id="$1"
    local tag_name="$2"
    local message="$3"
    {
        printf 'object %s\n' "$commit_id"
        printf 'type commit\n'
        printf 'tag %s\n' "$tag_name"
        printf 'tagger repository-sync-test <repository-sync-test@example.invalid> 946684800 +0000\n'
        printf '\n%s\n' "$message"
    } | git mktag
}

blob_source="$(blob 'internal source bytes')"
blob_later_source="$(blob 'later internal source bytes')"
blob_drift_source="$(blob 'drifted source bytes')"
blob_doc="$(blob 'internal documentation bytes')"
blob_extra_doc="$(blob 'extra documentation bytes')"
blob_tool="$(blob '#!/bin/sh\necho tool')"

tree_base="$(tree_with_tool "$blob_source" "$blob_doc" "$blob_tool" 100755 tool.sh)"
tree_later="$(tree_with_tool "$blob_later_source" "$blob_doc" "$blob_tool" 100755 tool.sh)"
tree_drift="$(tree_with_tool "$blob_drift_source" "$blob_doc" "$blob_tool" 100755 tool.sh)"
tree_doc_extra="$(tree_with_extra_doc "$blob_source" "$blob_doc" "$blob_tool" "$blob_extra_doc")"
tree_mode_changed="$(tree_with_tool "$blob_source" "$blob_doc" "$blob_tool" 100644 tool.sh)"
tree_path_changed="$(tree_with_tool "$blob_source" "$blob_doc" "$blob_tool" 100755 renamed-tool.sh)"

# Two unrelated roots intentionally have the same complete tree. This lets
# the tests distinguish tree equality from the required ancestry relationship.
internal_root="$(commit_with_tree "$tree_base" 'internal root')"
public_root="$(commit_with_tree "$tree_base" 'public root')"
isolated_same_tree="$(commit_with_tree "$tree_base" 'isolated same tree')"

# A valid first synchronization bridge: both unrelated roots are parents and
# the bridge preserves the internal tree exactly.
proper_bridge="$(commit_with_tree "$tree_base" 'proper bridge' "$internal_root" "$public_root")"

# Failure fixtures for each candidate invariant.
missing_public_base="$(commit_with_tree "$tree_base" 'missing public base' "$internal_root")"
content_drift="$(commit_with_tree "$tree_drift" 'content drift' "$internal_root" "$public_root")"
doc_drift="$(commit_with_tree "$tree_doc_extra" 'documentation drift' "$internal_root" "$public_root")"
mode_drift="$(commit_with_tree "$tree_mode_changed" 'file mode drift' "$internal_root" "$public_root")"
path_drift="$(commit_with_tree "$tree_path_changed" 'file path drift' "$internal_root" "$public_root")"

# A published merge keeps the internal commit as an ancestor and preserves its
# tree. A squash has the same tree but deliberately drops that ancestry.
published_merge="$(commit_with_tree "$tree_base" 'published merge' "$internal_root" "$public_root")"
published_squash="$(commit_with_tree "$tree_base" 'published squash')"

# A later cycle shares the first bridge's history. The public base is advanced
# from the first bridge and the internal side advances from the internal root.
internal_later="$(commit_with_tree "$tree_later" 'internal later' "$internal_root")"
public_later="$(commit_with_tree "$tree_base" 'public later' "$proper_bridge")"
later_bridge="$(commit_with_tree "$tree_later" 'later bridge' "$internal_later" "$public_later")"

# Annotated tags are intentionally different tag objects while peeling to the
# same internal commit. The wrong public tag peels to a different commit with
# the same complete tree, which must still fail exact release identity.
internal_tag_object="$(annotated_tag "$internal_root" 'internal-release-2.0.2' 'internal release')"
public_tag_object="$(annotated_tag "$internal_root" 'public-release-2.0.2' 'public release')"
public_wrong_tag_object="$(annotated_tag "$public_root" 'public-wrong-release-2.0.2' 'same tree, wrong commit')"
if [[ "$internal_tag_object" == "$public_tag_object" ]]; then
    printf 'FAIL: annotated tag objects unexpectedly match\n' >&2
    exit 1
fi

git update-ref refs/verify-sync/internal "$internal_root"
git update-ref refs/verify-sync/public-root "$public_root"
git update-ref refs/verify-sync/proper-bridge "$proper_bridge"
git update-ref refs/verify-sync/missing-public-base "$missing_public_base"
git update-ref refs/verify-sync/content-drift "$content_drift"
git update-ref refs/verify-sync/doc-drift "$doc_drift"
git update-ref refs/verify-sync/mode-drift "$mode_drift"
git update-ref refs/verify-sync/path-drift "$path_drift"
git update-ref refs/verify-sync/published-merge "$published_merge"
git update-ref refs/verify-sync/published-squash "$published_squash"
git update-ref refs/verify-sync/internal-later "$internal_later"
git update-ref refs/verify-sync/public-later "$public_later"
git update-ref refs/verify-sync/later-bridge "$later_bridge"
git update-ref refs/verify-sync/isolated-same-tree "$isolated_same_tree"
git update-ref refs/verify-sync/internal-tag "$internal_tag_object"
git update-ref refs/verify-sync/public-tag "$public_tag_object"
git update-ref refs/verify-sync/public-wrong-tag "$public_wrong_tag_object"

refs_before="$(git for-each-ref --format='%(refname) %(objectname)' refs/verify-sync)"
case_count=0

run_case() {
    local name="$1"
    local expected_rc="$2"
    shift 2
    local output_file="${fixture}/${name}.log"
    local rc=0
    local refs_after
    case_count=$((case_count + 1))

    # The absolute script path plus this fixture cwd verifies that the checker
    # does not accidentally resolve refs from its own source directory.
    if bash "$SCRIPT_PATH" "$@" >"$output_file" 2>&1; then
        rc=0
    else
        rc=$?
    fi

    if [[ "$rc" -ne "$expected_rc" ]]; then
        printf 'FAIL: %s expected exit=%s got exit=%s\n' "$name" "$expected_rc" "$rc" >&2
        cat "$output_file" >&2
        exit 1
    fi

    if [[ "$expected_rc" -eq 0 ]] && ! grep -q '^STATUS=PASS$' "$output_file"; then
        printf 'FAIL: %s did not report STATUS=PASS\n' "$name" >&2
        cat "$output_file" >&2
        exit 1
    fi
    if [[ "$expected_rc" -eq 1 ]] && ! grep -q '^STATUS=FAIL$' "$output_file"; then
        printf 'FAIL: %s did not report STATUS=FAIL\n' "$name" >&2
        cat "$output_file" >&2
        exit 1
    fi
    if [[ "$expected_rc" -eq 2 ]] && ! grep -Eq '^ERROR:|^Usage:' "$output_file"; then
        printf 'FAIL: %s did not report a usage/ref error\n' "$name" >&2
        cat "$output_file" >&2
        exit 1
    fi

    refs_after="$(git for-each-ref --format='%(refname) %(objectname)' refs/verify-sync)"
    if [[ "$refs_after" != "$refs_before" ]]; then
        printf 'FAIL: %s changed fixture refs\n' "$name" >&2
        diff -u <(printf '%s\n' "$refs_before") <(printf '%s\n' "$refs_after") >&2 || true
        exit 1
    fi
    printf 'OK: %s\n' "$name"
}

run_case 'identical-tree-without-internal-ancestry' 1 \
    candidate refs/verify-sync/internal refs/verify-sync/isolated-same-tree refs/verify-sync/isolated-same-tree
run_case 'candidate-missing-public-base-ancestry' 1 \
    candidate refs/verify-sync/internal refs/verify-sync/public-root refs/verify-sync/missing-public-base
run_case 'proper-bridge-with-unrelated-roots' 0 \
    candidate refs/verify-sync/internal refs/verify-sync/public-root refs/verify-sync/proper-bridge
run_case 'candidate-content-drift' 1 \
    candidate refs/verify-sync/internal refs/verify-sync/public-root refs/verify-sync/content-drift
run_case 'candidate-documentation-drift' 1 \
    candidate refs/verify-sync/internal refs/verify-sync/public-root refs/verify-sync/doc-drift
run_case 'candidate-file-mode-drift' 1 \
    candidate refs/verify-sync/internal refs/verify-sync/public-root refs/verify-sync/mode-drift
run_case 'candidate-file-path-drift' 1 \
    candidate refs/verify-sync/internal refs/verify-sync/public-root refs/verify-sync/path-drift
run_case 'published-merge-preserves-internal-tree' 0 \
    published refs/verify-sync/internal refs/verify-sync/published-merge
run_case 'published-squash-same-tree-without-ancestry' 1 \
    published refs/verify-sync/internal refs/verify-sync/published-squash
run_case 'later-sync-cycle-with-common-ancestry' 0 \
    candidate refs/verify-sync/internal-later refs/verify-sync/public-later refs/verify-sync/later-bridge
run_case 'annotated-tags-peel-to-frozen-internal-commit' 0 \
    tags refs/verify-sync/internal refs/verify-sync/internal-tag refs/verify-sync/public-tag
run_case 'same-tree-tag-with-different-commit-rejected' 1 \
    tags refs/verify-sync/internal refs/verify-sync/internal-tag refs/verify-sync/public-wrong-tag
run_case 'candidate-nonexistent-ref-rejected' 2 \
    candidate refs/verify-sync/missing refs/verify-sync/public-root refs/verify-sync/proper-bridge
run_case 'published-nonexistent-ref-rejected' 2 \
    published refs/verify-sync/internal refs/verify-sync/missing
run_case 'wrong-argument-count-rejected' 2 candidate refs/verify-sync/internal refs/verify-sync/public-root
run_case 'unknown-mode-rejected' 2 unknown refs/verify-sync/internal
run_case 'extra-argument-rejected' 2 published refs/verify-sync/internal refs/verify-sync/published-merge extra

# Every drift case has both required parent chains, so its failure must come
# from complete-tree comparison rather than an ancestry check.
for drift_case in candidate-content-drift candidate-documentation-drift candidate-file-mode-drift candidate-file-path-drift; do
    if ! grep -q '^TREE_EQUAL=FAIL$' "${fixture}/${drift_case}.log"; then
        printf 'FAIL: %s did not fail complete-tree equality\n' "$drift_case" >&2
        cat "${fixture}/${drift_case}.log" >&2
        exit 1
    fi
done

if ! grep -q '^INTERNAL_TAG_MATCH=PASS$' "${fixture}/annotated-tags-peel-to-frozen-internal-commit.log" ||
   ! grep -q '^PUBLIC_TAG_MATCH=PASS$' "${fixture}/annotated-tags-peel-to-frozen-internal-commit.log"; then
    printf 'FAIL: annotated tag positive case did not match frozen commit\n' >&2
    cat "${fixture}/annotated-tags-peel-to-frozen-internal-commit.log" >&2
    exit 1
fi
if ! grep -q '^PUBLIC_TAG_MATCH=FAIL$' "${fixture}/same-tree-tag-with-different-commit-rejected.log" ||
   ! grep -q '^TREE_EQUAL=PASS$' "${fixture}/same-tree-tag-with-different-commit-rejected.log"; then
    printf 'FAIL: same-tree wrong-commit tag case was not rejected by ID\n' >&2
    cat "${fixture}/same-tree-tag-with-different-commit-rejected.log" >&2
    exit 1
fi

printf 'PASS: verify-repository-sync regression tests (%s cases)\n' "$case_count"
