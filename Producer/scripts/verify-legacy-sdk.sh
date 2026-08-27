#!/usr/bin/env bash
#
# verify-legacy-sdk.sh — non-regression guard for the legacy VeTLSiOSSDK targets.
#
# Asserts that the Producer work did not touch VeTLSiOSSDK/,
# VeTLSiOSSDK-Example/ or VeTLSiOSSDK.xcworkspace/ (read-only git diff against
# master). On macOS, can optionally run the legacy SDK's xcodebuild tests
# (SKIP without tools).
#
# The git commands here are READ-ONLY (git diff); they never modify the
# working tree, index, or refs.
#
# Environment: any (git read-only); macOS for optional legacy tests.
# Evidence level: diff-based non-regression; ≠ full legacy test suite pass.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

echo "== verify-legacy-sdk (diff guard) =="

# Resolve the base ref: prefer local master, fall back to origin/master.
base_ref="master"
if ! git rev-parse --verify master >/dev/null 2>&1; then
    base_ref="origin/master"
fi
echo "Base ref: ${base_ref}"

# Read-only diff; never modifies the working tree. A git failure (e.g. base
# ref unresolvable) must FAIL, not be swallowed as an empty diff.
if ! diff_stat="$(git diff --stat "${base_ref}...HEAD" -- VeTLSiOSSDK/ VeTLSiOSSDK-Example/ VeTLSiOSSDK.xcworkspace/ 2>&1)"; then
    echo "FAIL: git diff against ${base_ref} failed:"
    echo "${diff_stat}"
    exit 1
fi

if [[ -n "${diff_stat}" ]]; then
    echo "FAIL: legacy SDK paths changed vs ${base_ref}:"
    echo "${diff_stat}"
    exit 1
fi

echo "PASS: no changes to VeTLSiOSSDK/, VeTLSiOSSDK-Example/ or VeTLSiOSSDK.xcworkspace/ vs ${base_ref}."

# Optional: legacy SDK tests on macOS.
echo "== legacy SDK xcodebuild tests (optional) =="
if command -v xcodebuild >/dev/null 2>&1; then
    if [[ -d VeTLSiOSSDK.xcworkspace ]]; then
        xcodebuild -workspace VeTLSiOSSDK.xcworkspace -scheme VeTLSiOSSDK test || {
            echo "FAIL: legacy SDK tests failed."
            exit 1
        }
    else
        echo "SKIP: VeTLSiOSSDK.xcworkspace not found."
    fi
else
    echo "SKIP: xcodebuild not found (needs macOS + Xcode)."
fi

echo "PASS: legacy SDK non-regression checks done."
