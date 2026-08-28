#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
BUNDLE_ID=com.volcengine.tls.SimulatorRecoveryHarness
BUILD_SCRIPT="$SCRIPT_DIR/build-simulator.sh"
CONFIGURATION=${TLS_SIMULATOR_BUILD_CONFIGURATION:-Debug}
DERIVED_DATA=${TLS_SIMULATOR_DERIVED_DATA_PATH:-"$PACKAGE_ROOT/.build/simulator-recovery-harness"}
APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphonesimulator/SimulatorRecoveryHarness.app"
DEVICE=${TLS_SIMULATOR_DEVICE_UDID:-}
SEED_COUNT=${TLS_SIMULATOR_SEED_COUNT:-}
REGION=${TLS_SIMULATOR_REGION:-}
PROJECT_ID=${TLS_SIMULATOR_PROJECT_ID:-}
TOPIC_ID=${TLS_SIMULATOR_TOPIC_ID:-}
ENDPOINT=${TLS_SIMULATOR_ENDPOINT:-}
RELEASE_FILE=${TLS_SIMULATOR_RECOVERY_RELEASE_FILE:-}
PRODUCER_ID=${TLS_SIMULATOR_PRODUCER_ID:-simulator-recovery-harness}
ROUND_TIMEOUT=${TLS_SIMULATOR_ROUND_TIMEOUT_SECONDS:-180}
RECOVERY_TIMEOUT=${TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS:-120}
ROUNDS_BUFFERED=${TLS_SIMULATOR_ROUNDS_BUFFERED:-50}
ROUNDS_SYNC=${TLS_SIMULATOR_ROUNDS_SYNC:-50}
REPORT_DIR=${TLS_SIMULATOR_REPORT_DIR:-"$PACKAGE_ROOT/.build/simulator-recovery-reports"}
REPORT_FILE=${TLS_SIMULATOR_REPORT_FILE:-"$REPORT_DIR/recovery-$(date +%Y%m%dT%H%M%S).tsv"}

if [[ "${TLS_SIMULATOR_RECOVERY_OPT_IN:-}" != "1" ]]; then
  echo "REFUSED: set TLS_SIMULATOR_RECOVERY_OPT_IN=1 to run the process-kill matrix" >&2
  exit 2
fi

if [[ -z "$ENDPOINT" ]]; then
  echo "ERROR: TLS_SIMULATOR_ENDPOINT is required" >&2
  exit 2
fi
if [[ -z "$REGION" ]]; then
  echo "ERROR: TLS_SIMULATOR_REGION is required" >&2
  exit 2
fi
if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: TLS_SIMULATOR_PROJECT_ID is required" >&2
  exit 2
fi
if [[ -z "$TOPIC_ID" ]]; then
  echo "ERROR: TLS_SIMULATOR_TOPIC_ID is required" >&2
  exit 2
fi
if [[ -z "$SEED_COUNT" ]]; then
  echo "ERROR: TLS_SIMULATOR_SEED_COUNT is required" >&2
  exit 2
fi
if [[ -z "$RELEASE_FILE" ]]; then
  echo "ERROR: TLS_SIMULATOR_RECOVERY_RELEASE_FILE is required" >&2
  exit 2
fi
if [[ -z "$DEVICE" ]]; then
  echo "ERROR: TLS_SIMULATOR_DEVICE_UDID is required and must identify a Booted simulator" >&2
  exit 2
fi

if ! [[ "$SEED_COUNT" =~ ^[1-9][0-9]*$ && "$ROUNDS_BUFFERED" =~ ^[0-9]+$ && "$ROUNDS_SYNC" =~ ^[0-9]+$ && "$ROUND_TIMEOUT" =~ ^[1-9][0-9]*$ && "$RECOVERY_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: seed, round, and timeout values must be positive decimal integers" >&2
  exit 2
fi

if ! [[ "$DEVICE" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]; then
  echo "ERROR: TLS_SIMULATOR_DEVICE_UDID is not a valid simulator identifier: $DEVICE" >&2
  exit 2
fi

if ! [[ "$RELEASE_FILE" == /* ]]; then
  echo "ERROR: TLS_SIMULATOR_RECOVERY_RELEASE_FILE must be an absolute path" >&2
  exit 2
fi
case "$RELEASE_FILE" in
  */../*|*/./*|*/.|*/..|*/)
    echo "ERROR: TLS_SIMULATOR_RECOVERY_RELEASE_FILE must not contain traversal or name a directory" >&2
    exit 2
    ;;
esac
GATE_ROOT=""
case "$RELEASE_FILE" in
  /tmp/*)
    GATE_ROOT=/tmp
    ;;
  "$PACKAGE_ROOT/.build"/*)
    GATE_ROOT="$PACKAGE_ROOT/.build"
    ;;
  *)
    echo "ERROR: release gate is limited to /tmp or $PACKAGE_ROOT/.build" >&2
    exit 2
    ;;
esac
GATE_PARENT=${RELEASE_FILE%/*}
GATE_NAME=${RELEASE_FILE##*/}
if [[ -z "$GATE_NAME" || "$GATE_NAME" == "." || "$GATE_NAME" == ".." ]]; then
  echo "ERROR: release gate must name a regular file" >&2
  exit 2
fi
mkdir -p "$GATE_PARENT"
GATE_PARENT_REAL=$(cd -- "$GATE_PARENT" && pwd -P)
GATE_ROOT_REAL=$(cd -- "$GATE_ROOT" && pwd -P)
case "$GATE_PARENT_REAL/" in
  "$GATE_ROOT_REAL/"*)
    ;;
  *)
    echo "ERROR: release gate resolves outside $GATE_ROOT_REAL" >&2
    exit 2
    ;;
esac
RELEASE_FILE="$GATE_PARENT_REAL/$GATE_NAME"
if [[ -L "$RELEASE_FILE" || ( -e "$RELEASE_FILE" && ! -f "$RELEASE_FILE" ) ]]; then
  echo "ERROR: release gate must be a regular non-symlink file: $RELEASE_FILE" >&2
  exit 2
fi

if [[ "${TLS_SIMULATOR_SKIP_BUILD:-0}" != "1" ]]; then
  "$BUILD_SCRIPT"
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: app not found; run build-simulator.sh or unset TLS_SIMULATOR_SKIP_BUILD" >&2
  exit 2
fi

if ! xcrun simctl list devices available 2>/dev/null | grep -Eq "\\($DEVICE\\).*\\(Booted\\)"; then
  echo "BLOCKED: simulator $DEVICE is not Booted; set TLS_SIMULATOR_DEVICE_UDID to a Booted device" >&2
  exit 3
fi

CONTAINER=""
STATE_FILE=""
RESULT_FILE=""
ENV_NAMES=(
  TLS_SIMULATOR_MODE
  TLS_SIMULATOR_ENDPOINT
  TLS_SIMULATOR_REGION
  TLS_SIMULATOR_PROJECT_ID
  TLS_SIMULATOR_TOPIC_ID
  TLS_SIMULATOR_PERSISTENCE
  TLS_SIMULATOR_PRODUCER_ID
  TLS_SIMULATOR_RUN_ID
  TLS_SIMULATOR_SEED_COUNT
  TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS
)

clear_simulator_environment() {
  for name in "${ENV_NAMES[@]}"; do
    xcrun simctl spawn "$DEVICE" launchctl unsetenv "$name" >/dev/null 2>&1 || true
  done
}
trap clear_simulator_environment EXIT

set_simulator_environment() {
  local mode=$1
  local persistence=$2
  local run_id=$3
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_MODE "$mode"
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_ENDPOINT "$ENDPOINT"
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_REGION "$REGION"
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_PROJECT_ID "$PROJECT_ID"
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_TOPIC_ID "$TOPIC_ID"
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_PERSISTENCE "$persistence"
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_PRODUCER_ID "$PRODUCER_ID"
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_RUN_ID "$run_id"
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_SEED_COUNT "$SEED_COUNT"
  xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS "$RECOVERY_TIMEOUT"
}

refresh_container_paths() {
  CONTAINER=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
  STATE_FILE="$CONTAINER/Documents/simulator-recovery-state.json"
  RESULT_FILE="$CONTAINER/Documents/simulator-recovery-result.json"
}

wait_for_file() {
  local file=$1
  local timeout=$2
  local start now
  start=$(date +%s)
  while :; do
    [[ -f "$file" ]] && return 0
    now=$(date +%s)
    (( now - start >= timeout )) && return 1
    sleep 1
  done
}

read_field() {
  local file=$1
  local field=$2
  plutil -extract "$field" raw -o - "$file" 2>/dev/null || true
}

install_fresh_app() {
  rm -f -- "$RELEASE_FILE"
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$DEVICE" "$APP_PATH"
  refresh_container_paths
}

create_release_gate_atomically() {
  local temporary_file="${RELEASE_FILE}.tmp.$$"
  rm -f -- "$temporary_file"
  : > "$temporary_file"
  mv -f -- "$temporary_file" "$RELEASE_FILE"
}

run_one_round() {
  local persistence=$1
  local round=$2
  local run_id="$(date +%Y%m%dT%H%M%S)-${persistence}-${round}"

  echo "[${persistence} ${round}] seed"
  install_fresh_app
  set_simulator_environment seed "$persistence" "$run_id"
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "--mode=seed" >/dev/null
  if ! wait_for_file "$STATE_FILE" "$ROUND_TIMEOUT"; then
    echo "BLOCKED: seed_ready marker did not appear (${persistence} round ${round})" >&2
    return 3
  fi
  if [[ "$(read_field "$STATE_FILE" marker)" != "seed_ready" ]]; then
    echo "FAIL: seed state marker is not seed_ready (${persistence} round ${round})" >&2
    return 1
  fi

  echo "[${persistence} ${round}] simctl terminate (process boundary)"
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID"

  # The HTTPS fixture holds/503s recovery requests while this host-side gate
  # is absent.  Only after terminate has returned do we release the fixture.
  create_release_gate_atomically

  echo "[${persistence} ${round}] recover"
  set_simulator_environment recover "$persistence" "$run_id"
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "--mode=recover" >/dev/null
  if ! wait_for_file "$RESULT_FILE" "$ROUND_TIMEOUT"; then
    echo "BLOCKED: recovery result marker did not appear (${persistence} round ${round})" >&2
    return 3
  fi

  local outcome observed expected successes failures
  outcome=$(read_field "$RESULT_FILE" outcome)
  observed=$(read_field "$RESULT_FILE" observedResultCount)
  expected=$(read_field "$RESULT_FILE" expectedResultCount)
  successes=$(read_field "$RESULT_FILE" successCount)
  failures=$(read_field "$RESULT_FILE" failureCount)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_id" "$persistence" "$round" "$outcome" "$expected/$observed" "$successes" "$failures" >> "$REPORT_FILE"

  case "$outcome" in
    success)
      if [[ "$successes" != "$expected" || "$failures" != "0" ]]; then
        echo "FAIL: recovery assertion successCount=${successes:-?}/${expected:-?} failureCount=${failures:-?}" >&2
        return 1
      fi
      echo "PASS: ${persistence} round ${round}, recovered ${successes}/${expected}"
      ;;
    blocked)
      echo "BLOCKED: no recovered SendResult; HTTPS fixture may be unavailable (${persistence} round ${round})" >&2
      return 3
      ;;
    *)
      echo "FAIL: recovery outcome=${outcome:-missing} observed=${observed:-?}/${expected:-?} successes=${successes:-?} failures=${failures:-?}" >&2
      return 1
      ;;
  esac
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

mkdir -p "$REPORT_DIR"
printf 'run_id\tpersistence\tround\toutcome\texpected/observed\tsuccesses\tfailures\n' > "$REPORT_FILE"
echo "Recovery report: $REPORT_FILE"

for ((round = 1; round <= ROUNDS_BUFFERED; round++)); do
  run_one_round buffered "$round"
done
for ((round = 1; round <= ROUNDS_SYNC; round++)); do
  run_one_round sync "$round"
done

echo "PASS: completed ${ROUNDS_BUFFERED} buffered + ${ROUNDS_SYNC} sync process-level recovery rounds"
