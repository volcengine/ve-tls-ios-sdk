#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
PROJECT="$PACKAGE_ROOT/Producer/Examples/SimulatorRecoveryHarness/SimulatorRecoveryHarness.xcodeproj"
SCHEME=SimulatorRecoveryHarness
CONFIGURATION=${TLS_SIMULATOR_BUILD_CONFIGURATION:-Debug}
DERIVED_DATA=${TLS_SIMULATOR_DERIVED_DATA_PATH:-"$PACKAGE_ROOT/.build/simulator-recovery-harness"}

if [[ ! -d "$PROJECT" ]]; then
  echo "ERROR: simulator recovery Xcode project not found: $PROJECT" >&2
  exit 2
fi

echo "Building $SCHEME for generic iOS Simulator ($CONFIGURATION)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphonesimulator/SimulatorRecoveryHarness.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: xcodebuild succeeded but app was not found: $APP_PATH" >&2
  exit 2
fi

echo "APP_PATH=$APP_PATH"
