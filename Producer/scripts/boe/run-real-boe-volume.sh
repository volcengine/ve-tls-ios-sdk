#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
BUNDLE_ID=com.volcengine.tls.SimulatorRecoveryHarness

# This is an intentionally explicit real-BOE gate.  No command in this file
# prints any of the destination or credential values.
if [[ "${TLS_RUN_REAL_BOE_VOLUME:-}" != "1" ]]; then
  echo "REFUSED: set TLS_RUN_REAL_BOE_VOLUME=1 after owner review" >&2
  exit 2
fi

DEVICE=${TLS_BOE_VOLUME_SIMULATOR_UDID:-${TLS_BOE_SIMULATOR_UDID:-${TLS_SIMULATOR_DEVICE_UDID:-}}}
DERIVED_DATA=${TLS_BOE_VOLUME_DERIVED_DATA:-/private/tmp/tls-boe-volume/RecoveryDerivedData}
EVIDENCE_DIR=${TLS_BOE_VOLUME_EVIDENCE_DIR:-/private/tmp/tls-boe-volume/evidence/volume}
CONFIGURATION=${TLS_BOE_VOLUME_CONFIGURATION:-${TLS_SIMULATOR_BUILD_CONFIGURATION:-Debug}}
ROUND_TIMEOUT=${TLS_BOE_VOLUME_ROUND_TIMEOUT_SECONDS:-1200}

ENDPOINT=${TLS_BOE_ENDPOINT:-${VE_TLS_ENDPOINT:-}}
REGION=${TLS_BOE_REGION:-${VE_TLS_REGION:-}}
PROJECT_ID=${TLS_BOE_PROJECT_ID:-${VE_TLS_PROJECT_ID:-boe-metadata-only}}
TOPIC_ID=${TLS_BOE_TOPIC_ID:-${VE_TLS_TOPIC_ID:-}}
ACCESS_KEY_ID=${TLS_BOE_ACCESS_KEY_ID:-${VE_TLS_ACCESS_KEY_ID:-}}
ACCESS_KEY_SECRET=${TLS_BOE_ACCESS_KEY_SECRET:-${VE_TLS_ACCESS_KEY_SECRET:-}}
SECURITY_TOKEN=${TLS_BOE_SECURITY_TOKEN:-${VE_TLS_SECURITY_TOKEN:-}}

APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphonesimulator/SimulatorRecoveryHarness.app"

if [[ -z "$DEVICE" || -z "$ENDPOINT" || -z "$REGION" || -z "$TOPIC_ID" ||
      -z "$ACCESS_KEY_ID" || -z "$ACCESS_KEY_SECRET" ]]; then
  echo "ERROR: BOE destination, credentials, and simulator UUID are required" >&2
  exit 2
fi
if ! [[ "$DEVICE" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]; then
  echo "ERROR: simulator UUID is invalid" >&2
  exit 2
fi
if ! [[ "$ROUND_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: volume round timeout must be a positive integer" >&2
  exit 2
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: SimulatorRecoveryHarness.app is missing; build it before running BOE volume" >&2
  exit 2
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "BLOCKED: xcrun is unavailable" >&2
  exit 3
fi
if ! command -v plutil >/dev/null 2>&1; then
  echo "BLOCKED: plutil is unavailable" >&2
  exit 3
fi
if ! xcrun simctl list devices available 2>/dev/null |
    grep -Eq "\($DEVICE\)[[:space:]].*\(Booted\)"; then
  echo "BLOCKED: selected simulator is not Booted" >&2
  exit 3
fi

PROFILES=(
  default-lz4
  no-compression-count
  buffered-high-concurrency
  sync-max-count
  complex-data-default
  complex-data-custom
  hash-routing
  hot-update
  auth-retain-bulk
)
PERSISTENCES=(disabled memory buffered sync memory memory memory memory sync)
EXPECTED_COUNTS=(10240 8192 12288 10000 2048 2048 4096 1024 512)
TARGET_RATE=200
RECOVERY_TIMEOUT=900
EXPECTED_TOTAL=$((10240 + 8192 + 12288 + 10000 + 2048 + 2048 + 4096 + 1024 + 512))
if (( EXPECTED_TOTAL != 50448 )); then
  echo "ERROR: internal volume matrix count is inconsistent" >&2
  exit 2
fi

mkdir -p "$EVIDENCE_DIR"
chmod 700 "$EVIDENCE_DIR"
SUMMARY_FILE="$EVIDENCE_DIR/volume-runs.tsv"
SUMMARY_HEADER='run_id	profile	persistence	expected	start_ms	end_ms	duplicate_policy	min_matched_shards	terminal_callbacks	result'
if [[ ! -e "$SUMMARY_FILE" ]]; then
  printf '%b\n' "$SUMMARY_HEADER" > "$SUMMARY_FILE"
elif [[ ! -f "$SUMMARY_FILE" ]]; then
  echo "ERROR: volume summary path is not a regular file" >&2
  exit 2
fi

CONTAINER=""
RESULT_FILE=""
PROFILE=""
PERSISTENCE=""
EXPECTED=""
RUN_ID=""
PRODUCER_ID=""
START_MS=""
END_MS=""
DUPLICATE_POLICY="forbid"
MIN_MATCHED_SHARDS=0
TERMINAL_CALLBACKS=0

cleanup() {
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

read_result_field() {
  local file=$1
  local field=$2
  plutil -extract "$field" raw -o - "$file" 2>/dev/null || true
}

append_summary_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$RUN_ID" "$PROFILE" "$PERSISTENCE" "$EXPECTED" "$START_MS" "$END_MS" \
    "$DUPLICATE_POLICY" "$MIN_MATCHED_SHARDS" "$TERMINAL_CALLBACKS" "$1" \
    >> "$SUMMARY_FILE"
}

round_fail() {
  local reason=$1
  END_MS=$(( $(date +%s) * 1000 + 120000 ))
  append_summary_row fail
  echo "FAIL: BOE volume round failed profile=$PROFILE persistence=$PERSISTENCE run_id=$RUN_ID reason=$reason" >&2
  exit 1
}

wait_for_result() {
  local deadline=$(( $(date +%s) + ROUND_TIMEOUT ))
  while [[ ! -f "$RESULT_FILE" ]]; do
    if (( $(date +%s) >= deadline )); then
      return 1
    fi
    sleep 1
  done
}

refresh_container() {
  if ! CONTAINER=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data 2>/dev/null); then
    return 1
  fi
  [[ -n "$CONTAINER" ]] || return 1
  RESULT_FILE="$CONTAINER/Documents/simulator-volume-result.json"
}

launch_volume() {
  SIMCTL_CHILD_TLS_SIMULATOR_MODE=volume \
  SIMCTL_CHILD_TLS_SIMULATOR_VOLUME_PROFILE="$PROFILE" \
  SIMCTL_CHILD_TLS_SIMULATOR_PROFILE="$PROFILE" \
  SIMCTL_CHILD_TLS_SIMULATOR_SCENARIO="$PROFILE" \
  SIMCTL_CHILD_TLS_SIMULATOR_PERSISTENCE="$PERSISTENCE" \
  SIMCTL_CHILD_TLS_SIMULATOR_SEED_COUNT="$EXPECTED" \
  SIMCTL_CHILD_TLS_SIMULATOR_TARGET_LOGS_PER_SECOND="$TARGET_RATE" \
  SIMCTL_CHILD_TLS_SIMULATOR_TARGET_RATE="$TARGET_RATE" \
  SIMCTL_CHILD_TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS="$RECOVERY_TIMEOUT" \
  SIMCTL_CHILD_TLS_SIMULATOR_PRODUCER_ID="$PRODUCER_ID" \
  SIMCTL_CHILD_TLS_SIMULATOR_RUN_ID="$RUN_ID" \
  SIMCTL_CHILD_TLS_SIMULATOR_ENDPOINT="$ENDPOINT" \
  SIMCTL_CHILD_TLS_SIMULATOR_REGION="$REGION" \
  SIMCTL_CHILD_TLS_SIMULATOR_PROJECT_ID="$PROJECT_ID" \
  SIMCTL_CHILD_TLS_SIMULATOR_TOPIC_ID="$TOPIC_ID" \
  SIMCTL_CHILD_TLS_SIMULATOR_ACCESS_KEY_ID="$ACCESS_KEY_ID" \
  SIMCTL_CHILD_TLS_SIMULATOR_ACCESS_KEY_SECRET="$ACCESS_KEY_SECRET" \
  SIMCTL_CHILD_TLS_SIMULATOR_SECURITY_TOKEN="$SECURITY_TOKEN" \
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1
}

run_round() {
  local index=$1
  PROFILE=${PROFILES[$index]}
  PERSISTENCE=${PERSISTENCES[$index]}
  EXPECTED=${EXPECTED_COUNTS[$index]}
  MIN_MATCHED_SHARDS=0
  if [[ "$PROFILE" == "hash-routing" ]]; then
    MIN_MATCHED_SHARDS=8
  fi

  RUN_ID="boe_volume_${index}_${PROFILE}_${PERSISTENCE}_$(date -u +%Y%m%d%H%M%S)_$$-${RANDOM}"
  PRODUCER_ID="bv-${index}-${PERSISTENCE}-$$-${RANDOM}"
  START_MS=$(( $(date +%s) * 1000 - 60000 ))
  TERMINAL_CALLBACKS=0
  if ! [[ "$RUN_ID" =~ ^[a-z0-9_-]+$ ]]; then
    round_fail run_id
  fi
  if ! [[ "$PRODUCER_ID" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    round_fail producer_id
  fi

  echo "BOE_VOLUME_START profile=$PROFILE persistence=$PERSISTENCE run_id=$RUN_ID expected=$EXPECTED"
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if ! xcrun simctl install "$DEVICE" "$APP_PATH" >/dev/null 2>&1; then
    round_fail install
  fi
  if ! refresh_container; then
    round_fail container
  fi
  if ! launch_volume; then
    round_fail launch
  fi
  if ! wait_for_result; then
    round_fail result_timeout
  fi
  if ! cp "$RESULT_FILE" "$EVIDENCE_DIR/${RUN_ID}-result.json"; then
    round_fail result_copy
  fi

  local marker outcome accepted observed_raw admitted_field failures close_outcome
  local observed_callbacks success_callbacks result_run_id result_profile
  local result_persistence compressed_bytes
  marker=$(read_result_field "$RESULT_FILE" marker)
  result_run_id=$(read_result_field "$RESULT_FILE" runID)
  result_profile=$(read_result_field "$RESULT_FILE" profile)
  result_persistence=$(read_result_field "$RESULT_FILE" persistence)
  outcome=$(read_result_field "$RESULT_FILE" outcome)
  accepted=$(read_result_field "$RESULT_FILE" acceptedLogCount)
  observed_raw=$(read_result_field "$RESULT_FILE" observedRawBytes)
  admitted_field=$(read_result_field "$RESULT_FILE" admittedFieldBytes)
  failures=$(read_result_field "$RESULT_FILE" failureCount)
  close_outcome=$(read_result_field "$RESULT_FILE" closeOutcome)
  observed_callbacks=$(read_result_field "$RESULT_FILE" observedResultCount)
  success_callbacks=$(read_result_field "$RESULT_FILE" successCount)
  compressed_bytes=$(read_result_field "$RESULT_FILE" compressedBytes)
  TERMINAL_CALLBACKS=${observed_callbacks:-0}

  [[ "$marker" == "volume_result_ready" ]] || round_fail marker
  [[ "$result_run_id" == "$RUN_ID" ]] || round_fail run_id_mismatch
  [[ "$result_profile" == "$PROFILE" ]] || round_fail profile_mismatch
  [[ "$result_persistence" == "$PERSISTENCE" ]] || round_fail persistence_mismatch
  [[ "$outcome" == "success" ]] || round_fail outcome
  if ! [[ "$accepted" =~ ^[0-9]+$ && "$accepted" == "$EXPECTED" ]]; then
    round_fail accepted_count
  fi
  if ! [[ "$observed_raw" =~ ^[0-9]+$ && "$admitted_field" =~ ^[0-9]+$ &&
          "$admitted_field" -gt 0 && "$observed_raw" -ge "$admitted_field" ]]; then
    round_fail raw_bytes
  fi
  [[ "$failures" == "0" ]] || round_fail failures
  [[ "$close_outcome" == "success" ]] || round_fail close
  if ! [[ "$observed_callbacks" =~ ^[0-9]+$ && "$success_callbacks" =~ ^[0-9]+$ ]]; then
    round_fail callback_fields
  fi
  if [[ "$success_callbacks" != "$observed_callbacks" ]]; then
    round_fail callback_mismatch
  fi
  if ! [[ "$compressed_bytes" =~ ^[0-9]+$ && "$compressed_bytes" -gt 0 ]]; then
    round_fail compressed_bytes
  fi
  case "$PROFILE" in
    no-compression-count)
      [[ "$observed_callbacks" == "32" ]] || round_fail callback_count
      ;;
    buffered-high-concurrency)
      [[ "$observed_callbacks" == "3" ]] || round_fail callback_count
      ;;
    sync-max-count)
      [[ "$observed_callbacks" == "1" ]] || round_fail callback_count
      ;;
    auth-retain-bulk)
      [[ "$observed_callbacks" == "1" ]] || round_fail callback_count
      ;;
    *)
      (( observed_callbacks > 0 )) || round_fail callback_count
      ;;
  esac

  END_MS=$(( $(date +%s) * 1000 + 120000 ))
  append_summary_row success
  echo "BOE_VOLUME_OK profile=$PROFILE persistence=$PERSISTENCE run_id=$RUN_ID expected=$EXPECTED terminal_callbacks=$TERMINAL_CALLBACKS result=$EVIDENCE_DIR/${RUN_ID}-result.json"
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

for (( index = 0; index < ${#PROFILES[@]}; index++ )); do
  run_round "$index"
done

echo "BOE_VOLUME_MATRIX_OK rounds=${#PROFILES[@]} expected_total=$EXPECTED_TOTAL summary=$SUMMARY_FILE"
