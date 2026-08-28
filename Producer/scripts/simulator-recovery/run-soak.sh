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
ENDPOINT=${TLS_SIMULATOR_ENDPOINT:-}
REGION=${TLS_SIMULATOR_REGION:-}
PROJECT_ID=${TLS_SIMULATOR_PROJECT_ID:-}
TOPIC_ID=${TLS_SIMULATOR_TOPIC_ID:-}
PERSISTENCE=${TLS_SIMULATOR_PERSISTENCE:-buffered}
PRODUCER_ID=${TLS_SIMULATOR_PRODUCER_ID:-simulator-recovery-harness}
SOAK_DURATION=${TLS_SIMULATOR_SOAK_DURATION_SECONDS:-7200}
SOAK_INTERVAL_MS=${TLS_SIMULATOR_SOAK_INTERVAL_MS:-1000}
TIMEOUT_GRACE=${TLS_SIMULATOR_SOAK_GRACE_SECONDS:-30}
SOAK_DRAIN_TIMEOUT=${TLS_SIMULATOR_SOAK_DRAIN_TIMEOUT_SECONDS:-30}
RUN_ID=${TLS_SIMULATOR_RUN_ID:-"$(date +%Y%m%dT%H%M%S)-soak"}
SAFE_RUN_ID=$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9._-' '_')
MEMORY_REPORT_DIR="$PACKAGE_ROOT/.build/simulator-recovery-reports"
MEMORY_REPORT="$MEMORY_REPORT_DIR/soak-memory-${SAFE_RUN_ID}.tsv"

if [[ "${TLS_SIMULATOR_RECOVERY_OPT_IN:-}" != "1" ]]; then
  echo "REFUSED: set TLS_SIMULATOR_RECOVERY_OPT_IN=1 to run the soak" >&2
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
if [[ -z "$DEVICE" ]]; then
  echo "ERROR: TLS_SIMULATOR_DEVICE_UDID is required and must identify a Booted simulator" >&2
  exit 2
fi
if ! [[ "$DEVICE" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]; then
  echo "ERROR: TLS_SIMULATOR_DEVICE_UDID is not a valid simulator identifier: $DEVICE" >&2
  exit 2
fi
if [[ "$PERSISTENCE" != "buffered" && "$PERSISTENCE" != "sync" ]]; then
  echo "ERROR: TLS_SIMULATOR_PERSISTENCE must be buffered or sync" >&2
  exit 2
fi
if ! [[ "$SOAK_DURATION" =~ ^[0-9]+([.][0-9]+)?$ && "$SOAK_INTERVAL_MS" =~ ^[1-9][0-9]*$ && "$TIMEOUT_GRACE" =~ ^[0-9]+$ && "$SOAK_DRAIN_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: soak duration/interval/grace values are invalid" >&2
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

ENV_NAMES=(
  TLS_SIMULATOR_MODE
  TLS_SIMULATOR_ENDPOINT
  TLS_SIMULATOR_REGION
  TLS_SIMULATOR_PROJECT_ID
  TLS_SIMULATOR_TOPIC_ID
  TLS_SIMULATOR_PERSISTENCE
  TLS_SIMULATOR_PRODUCER_ID
  TLS_SIMULATOR_RUN_ID
  TLS_SIMULATOR_SOAK_DURATION_SECONDS
  TLS_SIMULATOR_SOAK_INTERVAL_MS
  TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS
)
clear_simulator_environment() {
  for name in "${ENV_NAMES[@]}"; do
    xcrun simctl spawn "$DEVICE" launchctl unsetenv "$name" >/dev/null 2>&1 || true
  done
}
cleanup() {
  clear_simulator_environment
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$APP_PATH"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
RESULT_FILE="$CONTAINER/Documents/simulator-recovery-result.json"
mkdir -p "$MEMORY_REPORT_DIR"
printf 'elapsed_seconds\tpid\trss_kb\n' > "$MEMORY_REPORT"

sample_memory() {
  local elapsed=$1
  local process_sample
  # Match only the PID returned by `simctl launch`. Searching the command line
  # for APP_EXECUTABLE is unsafe: the sampler's own awk argv contains that
  # same path and can be mistaken for the app after host PID wraparound.
  process_sample=$(ps -o pid=,rss= -p "$APP_PID" 2>/dev/null | awk '
    NF == 2 { print $1 "\t" $2; exit }
  ' || true)
  if [[ -n "$process_sample" ]]; then
    printf '%s\t%s\n' "$elapsed" "$process_sample" >> "$MEMORY_REPORT"
  fi
}

xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_MODE soak
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_ENDPOINT "$ENDPOINT"
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_REGION "$REGION"
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_PROJECT_ID "$PROJECT_ID"
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_TOPIC_ID "$TOPIC_ID"
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_PERSISTENCE "$PERSISTENCE"
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_PRODUCER_ID "$PRODUCER_ID"
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_RUN_ID "$RUN_ID"
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_SOAK_DURATION_SECONDS "$SOAK_DURATION"
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_SOAK_INTERVAL_MS "$SOAK_INTERVAL_MS"
xcrun simctl spawn "$DEVICE" launchctl setenv TLS_SIMULATOR_RECOVERY_TIMEOUT_SECONDS "$SOAK_DRAIN_TIMEOUT"

echo "Starting ${SOAK_DURATION}s ${PERSISTENCE} soak (run_id=${RUN_ID})"
launch_output=$(xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "--mode=soak")
APP_PID=$(printf '%s\n' "$launch_output" | sed -n 's/.*: \([0-9][0-9]*\)$/\1/p' | tail -n 1)
if ! [[ "$APP_PID" =~ ^[1-9][0-9]*$ ]]; then
  echo "BLOCKED: simctl did not return the launched app PID" >&2
  exit 3
fi
echo "Harness PID: $APP_PID"

wait_seconds=$(awk "BEGIN { print int($SOAK_DURATION + $SOAK_DRAIN_TIMEOUT + $TIMEOUT_GRACE) }")
start=$(date +%s)
while [[ ! -f "$RESULT_FILE" ]]; do
  now=$(date +%s)
  sample_memory "$((now - start))"
  if (( now - start >= wait_seconds )); then
    echo "BLOCKED: soak result marker did not appear; HTTPS fixture or app may be unavailable" >&2
    exit 3
  fi
  sleep 1
done
sample_memory "$(( $(date +%s) - start ))"

memory_summary=$(awk '
  NR == 2 { first=$3; min=$3; max=$3 }
  NR > 1 {
    pid[$2] = 1
    last=$3
    if ($3 < min) min=$3
    if ($3 > max) max=$3
    count++
    if ($1 >= 300) {
      warm_count++
      warm_last=$3
      if (warm_count == 1) {
        warm_first=$3
        warm_min=$3
        warm_max=$3
      }
      if ($3 < warm_min) warm_min=$3
      if ($3 > warm_max) warm_max=$3
      sx += $1
      sy += $3
      sxx += $1 * $1
      sxy += $1 * $3
    }
  }
  END {
    if (count > 0) {
      printf "samples=%d pid_count=%d first_kb=%d last_kb=%d min_kb=%d max_kb=%d delta_kb=%d", count, length(pid), first, last, min, max, last-first
      if (warm_count > 1) {
        denominator = warm_count * sxx - sx * sx
        slope_per_second = denominator == 0 ? 0 : (warm_count * sxy - sx * sy) / denominator
        printf " post300_samples=%d post300_first_kb=%d post300_last_kb=%d post300_min_kb=%d post300_max_kb=%d post300_delta_kb=%d post300_slope_kb_per_hour=%.2f", warm_count, warm_first, warm_last, warm_min, warm_max, warm_last-warm_first, slope_per_second * 3600
      }
    }
  }
' "$MEMORY_REPORT")
if [[ -n "$memory_summary" ]]; then
  echo "RSS: $memory_summary"
  echo "Memory report: $MEMORY_REPORT"
else
  echo "SKIP: host RSS sampling was unavailable; callback soak assertions still ran."
fi

outcome=$(plutil -extract outcome raw -o - "$RESULT_FILE" 2>/dev/null || true)
accepted=$(plutil -extract acceptedLogCount raw -o - "$RESULT_FILE" 2>/dev/null || true)
observed=$(plutil -extract observedResultCount raw -o - "$RESULT_FILE" 2>/dev/null || true)
successes=$(plutil -extract successCount raw -o - "$RESULT_FILE" 2>/dev/null || true)
failures=$(plutil -extract failureCount raw -o - "$RESULT_FILE" 2>/dev/null || true)
if [[ "$outcome" == "completed" && "$accepted" == "$observed" && "$accepted" == "$successes" && "$failures" == "0" ]]; then
  echo "PASS: soak completed accepted=${accepted:-?} observed=${observed:-?} successes=${successes:-?} failures=${failures:-?}"
  exit 0
fi
if [[ "$outcome" == "blocked" ]]; then
  echo "BLOCKED: soak did not receive SendResult callbacks" >&2
  exit 3
fi
echo "FAIL: soak outcome=${outcome:-missing} accepted=${accepted:-?} observed=${observed:-?}" >&2
exit 1
