#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
BUNDLE_ID=com.volcengine.tls.SimulatorRecoveryHarness
DEVICE=${TLS_BOE_SIMULATOR_UDID:-}
DERIVED_DATA=${TLS_BOE_RECOVERY_DERIVED_DATA:-/private/tmp/tls-boe-acceptance/RecoveryDerivedData}
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/SimulatorRecoveryHarness.app"
EVIDENCE_DIR=${TLS_BOE_RECOVERY_EVIDENCE_DIR:-/private/tmp/tls-boe-acceptance/evidence/recovery}
SEED_COUNT=${TLS_BOE_RECOVERY_SEED_COUNT:-3}
ROUND_TIMEOUT=${TLS_BOE_RECOVERY_ROUND_TIMEOUT_SECONDS:-120}

ENDPOINT=${TLS_BOE_ENDPOINT:-${VE_TLS_ENDPOINT:-}}
REGION=${TLS_BOE_REGION:-${VE_TLS_REGION:-}}
PROJECT_ID=${TLS_BOE_PROJECT_ID:-${VE_TLS_PROJECT_ID:-boe-metadata-only}}
TOPIC_ID=${TLS_BOE_TOPIC_ID:-${VE_TLS_TOPIC_ID:-}}
ACCESS_KEY_ID=${TLS_BOE_ACCESS_KEY_ID:-${VE_TLS_ACCESS_KEY_ID:-}}
ACCESS_KEY_SECRET=${TLS_BOE_ACCESS_KEY_SECRET:-${VE_TLS_ACCESS_KEY_SECRET:-}}
SECURITY_TOKEN=${TLS_BOE_SECURITY_TOKEN:-${VE_TLS_SECURITY_TOKEN:-}}

if [[ "${TLS_RUN_REAL_BOE_RECOVERY:-}" != "1" ]]; then
  echo "REFUSED: set TLS_RUN_REAL_BOE_RECOVERY=1 after owner review" >&2
  exit 2
fi
if [[ -z "$DEVICE" || -z "$ENDPOINT" || -z "$REGION" || -z "$TOPIC_ID" || -z "$ACCESS_KEY_ID" || -z "$ACCESS_KEY_SECRET" ]]; then
  echo "ERROR: BOE destination, credentials, and TLS_BOE_SIMULATOR_UDID are required" >&2
  exit 2
fi
if ! [[ "$DEVICE" =~ ^[A-Fa-f0-9-]{36}$ && "$SEED_COUNT" =~ ^[1-9][0-9]*$ && "$ROUND_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: simulator identifier, seed count, or timeout is invalid" >&2
  exit 2
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: recovery harness app is missing; build it before running BOE recovery" >&2
  exit 2
fi
if ! xcrun simctl list devices available 2>/dev/null | grep -Eq "\($DEVICE\).*\(Booted\)"; then
  echo "BLOCKED: selected simulator is not Booted" >&2
  exit 3
fi

mkdir -p "$EVIDENCE_DIR"
chmod 700 "$EVIDENCE_DIR"
SUMMARY_FILE="$EVIDENCE_DIR/recovery-runs.tsv"
printf 'run_id\tfault\tpersistence\texpected\tstart_ms\tend_ms\tduplicate_policy\tresult\n' > "$SUMMARY_FILE"

CONTAINER=""
STATE_FILE=""
NETWORK_FILE=""
RESULT_FILE=""

cleanup() {
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

refresh_paths() {
  CONTAINER=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
  STATE_FILE="$CONTAINER/Documents/simulator-recovery-state.json"
  NETWORK_FILE="$CONTAINER/Documents/simulator-recovery-network-marker.json"
  RESULT_FILE="$CONTAINER/Documents/simulator-recovery-result.json"
}

wait_for_file() {
  local path=$1
  local timeout=$2
  local started now
  started=$(date +%s)
  while [[ ! -f "$path" ]]; do
    now=$(date +%s)
    if (( now - started >= timeout )); then
      return 1
    fi
    sleep 1
  done
}

read_field() {
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

launch_harness() {
  local mode=$1
  local persistence=$2
  local producer_id=$3
  local run_id=$4
  local scenario=$5
  local fault=$6

  SIMCTL_CHILD_TLS_SIMULATOR_MODE="$mode" \
  SIMCTL_CHILD_TLS_SIMULATOR_ENDPOINT="$ENDPOINT" \
  SIMCTL_CHILD_TLS_SIMULATOR_REGION="$REGION" \
  SIMCTL_CHILD_TLS_SIMULATOR_PROJECT_ID="$PROJECT_ID" \
  SIMCTL_CHILD_TLS_SIMULATOR_TOPIC_ID="$TOPIC_ID" \
  SIMCTL_CHILD_TLS_SIMULATOR_PERSISTENCE="$persistence" \
  SIMCTL_CHILD_TLS_SIMULATOR_PRODUCER_ID="$producer_id" \
  SIMCTL_CHILD_TLS_SIMULATOR_RUN_ID="$run_id" \
  SIMCTL_CHILD_TLS_SIMULATOR_SCENARIO="$scenario" \
  SIMCTL_CHILD_TLS_SIMULATOR_NETWORK_FAULT="$fault" \
  SIMCTL_CHILD_TLS_SIMULATOR_SEED_COUNT="$SEED_COUNT" \
  SIMCTL_CHILD_TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS="$ROUND_TIMEOUT" \
  SIMCTL_CHILD_TLS_SIMULATOR_ACCESS_KEY_ID="$ACCESS_KEY_ID" \
  SIMCTL_CHILD_TLS_SIMULATOR_ACCESS_KEY_SECRET="$ACCESS_KEY_SECRET" \
  SIMCTL_CHILD_TLS_SIMULATOR_SECURITY_TOKEN="$SECURITY_TOKEN" \
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
}

run_round() {
  local fault=$1
  local persistence=$2
  local fault_slug scenario duplicate_policy run_id producer_id start_ms end_ms
  fault_slug=${fault//-/_}
  scenario="wal_${fault_slug}"
  run_id="ios_boe_${fault_slug}_${persistence}_$(date -u +%Y%m%d%H%M%S)_${RANDOM}"
  producer_id="boe-recovery-${fault}-${persistence}"
  duplicate_policy=forbid
  if [[ "$fault" == "lose-ack-after-200" ]]; then
    duplicate_policy=require
  fi
  start_ms=$(( $(date +%s) * 1000 - 60000 ))

  echo "BOE_RECOVERY_START fault=$fault persistence=$persistence run_id=$run_id"
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$DEVICE" "$APP_PATH"
  refresh_paths

  launch_harness seed "$persistence" "$producer_id" "$run_id" "$scenario" "$fault"
  if ! wait_for_file "$STATE_FILE" "$ROUND_TIMEOUT"; then
    echo "BLOCKED: seed state marker did not appear" >&2
    return 3
  fi
  if ! wait_for_file "$NETWORK_FILE" "$ROUND_TIMEOUT"; then
    echo "BLOCKED: network fault marker did not appear" >&2
    return 3
  fi
  if [[ "$(read_field "$STATE_FILE" marker)" != "seed_ready" ||
        "$(read_field "$NETWORK_FILE" marker)" != "network_fault_ready" ]]; then
    echo "FAIL: seed or network marker is invalid" >&2
    return 1
  fi
  if [[ "$fault" == "lose-ack-after-200" ]]; then
    if [[ "$(read_field "$NETWORK_FILE" serverAccepted)" != "true" ||
          "$(read_field "$NETWORK_FILE" httpStatus)" != "200" ]]; then
      echo "FAIL: lost-ACK fault did not observe a BOE HTTP 200" >&2
      return 1
    fi
  elif [[ "$(read_field "$NETWORK_FILE" serverAccepted)" != "false" ]]; then
    echo "FAIL: blocked-before-send unexpectedly reached BOE" >&2
    return 1
  fi

  cp "$STATE_FILE" "$EVIDENCE_DIR/${run_id}-seed.json"
  cp "$NETWORK_FILE" "$EVIDENCE_DIR/${run_id}-network.json"
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID"

  launch_harness recover "$persistence" "$producer_id" "$run_id" "$scenario" direct
  if ! wait_for_file "$RESULT_FILE" "$ROUND_TIMEOUT"; then
    echo "BLOCKED: recovery result marker did not appear" >&2
    return 3
  fi
  cp "$RESULT_FILE" "$EVIDENCE_DIR/${run_id}-result.json"
  if [[ "$(read_field "$RESULT_FILE" outcome)" != "success" ||
        "$(read_field "$RESULT_FILE" successCount)" != "$SEED_COUNT" ||
        "$(read_field "$RESULT_FILE" failureCount)" != "0" ]]; then
    echo "FAIL: recovered callbacks do not match admitted WAL records" >&2
    return 1
  fi
  end_ms=$(( $(date +%s) * 1000 + 120000 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$fault" "$persistence" "$SEED_COUNT" "$start_ms" "$end_ms" \
    "$duplicate_policy" success >> "$SUMMARY_FILE"
  echo "BOE_RECOVERY_LOCAL_OK fault=$fault persistence=$persistence run_id=$run_id"
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

for fault in block-before-send lose-ack-after-200; do
  for persistence in buffered sync; do
    run_round "$fault" "$persistence"
  done
done

echo "BOE_RECOVERY_LOCAL_MATRIX_OK rounds=4 summary=$SUMMARY_FILE"
