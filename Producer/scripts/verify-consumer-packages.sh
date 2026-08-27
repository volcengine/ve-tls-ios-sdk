#!/usr/bin/env bash
#
# verify-consumer-packages.sh — build/test the Producer via SwiftPM and CocoaPods.
#
# On macOS, runs in order:
#   1. swift build
#   2. swift test
#   3. xcodebuild (scheme from $1 or auto-discovered)
#   4. pod lib lint (--allow-warnings)
#
# Each step SKIPs with a clear message if its tool is missing (never fakes
# green). On the Linux dev machine all steps SKIP.
#
# Usage: verify-consumer-packages.sh [xcode-scheme]
#
# Environment: macOS with Xcode + Swift + CocoaPods.
# Evidence level: build/test pass ≠ device/Beta pass; see DECISIONS.md.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

SCHEME="${1:-}"
overall=0
ran=0

# 1. swift build
echo "== swift build =="
if command -v swift >/dev/null 2>&1; then
    ran=1
    swift build || overall=1
else
    echo "SKIP: swift not found (needs macOS + Xcode)."
fi

# 2. swift test
echo "== swift test =="
if command -v swift >/dev/null 2>&1; then
    ran=1
    swift test || overall=1
else
    echo "SKIP: swift not found (needs macOS + Xcode)."
fi

# 3. xcodebuild
echo "== xcodebuild =="
if command -v xcodebuild >/dev/null 2>&1; then
    if [[ -z "${SCHEME}" ]]; then
        # Auto-discover: pick the VolcengineTLSProducer scheme if present.
        SCHEME="$(xcodebuild -list 2>/dev/null | grep -A100 'Schemes:' | grep -m1 'VolcengineTLSProducer' | tr -d '[:space:]' || true)"
    fi
    if [[ -n "${SCHEME}" ]]; then
        ran=1
        xcodebuild -scheme "${SCHEME}" build || overall=1
    else
        echo "SKIP: no VolcengineTLSProducer scheme found (pass one as \$1)."
    fi
else
    echo "SKIP: xcodebuild not found (needs macOS + Xcode)."
fi

# 4. pod lib lint
echo "== pod lib lint =="
if command -v pod >/dev/null 2>&1; then
    ran=1
    pod lib lint VolcengineTLSProducer.podspec --allow-warnings || overall=1
else
    echo "SKIP: pod not found (needs macOS + CocoaPods)."
fi

echo ""
if [[ "${ran}" -eq 0 ]]; then
    echo "SKIP: no package tools available on this host (needs macOS + Xcode + CocoaPods)."
elif [[ "${overall}" -eq 0 ]]; then
    echo "PASS: consumer package verification completed."
else
    echo "FAIL: one or more package verification steps failed."
fi
exit "${overall}"
