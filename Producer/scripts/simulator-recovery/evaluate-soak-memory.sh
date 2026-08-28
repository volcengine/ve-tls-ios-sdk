#!/bin/bash
set -euo pipefail

REPORT=${1:-}
REQUIRED_ELAPSED_SECONDS=${TLS_SOAK_MEMORY_REQUIRED_ELAPSED_SECONDS:-${TLS_SIMULATOR_SOAK_DURATION_SECONDS:-0}}
ELAPSED_TOLERANCE_SECONDS=${TLS_SOAK_MEMORY_ELAPSED_TOLERANCE_SECONDS:-5}
MIN_TREND_ELAPSED_SECONDS=${TLS_SOAK_MEMORY_MIN_TREND_ELAPSED_SECONDS:-900}
MIN_COVERAGE_PERCENT=${TLS_SOAK_MEMORY_MIN_COVERAGE_PERCENT:-95}
MAX_GAP_SECONDS=${TLS_SOAK_MEMORY_MAX_GAP_SECONDS:-10}
MAX_MEDIAN_GROWTH_KB=${TLS_SOAK_MEMORY_MAX_MEDIAN_GROWTH_KB:-8192}
MAX_SLOPE_KB_PER_HOUR=${TLS_SOAK_MEMORY_MAX_SLOPE_KB_PER_HOUR:-4096}

if [[ -z "$REPORT" || ! -f "$REPORT" ]]; then
  echo "FAIL: RSS report is missing" >&2
  exit 1
fi
if ! [[ "$REQUIRED_ELAPSED_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ &&
        "$ELAPSED_TOLERANCE_SECONDS" =~ ^[0-9]+$ &&
        "$MIN_TREND_ELAPSED_SECONDS" =~ ^[1-9][0-9]*$ &&
        "$MIN_COVERAGE_PERCENT" =~ ^[1-9][0-9]*([.][0-9]+)?$ &&
        "$MAX_GAP_SECONDS" =~ ^[1-9][0-9]*$ &&
        "$MAX_MEDIAN_GROWTH_KB" =~ ^-?[0-9]+([.][0-9]+)?$ &&
        "$MAX_SLOPE_KB_PER_HOUR" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
  echo "FAIL: RSS gate thresholds are invalid" >&2
  exit 1
fi

header=$(head -n 1 "$REPORT")
if [[ "$header" != $'elapsed_seconds\tpid\trss_kb' ]]; then
  echo "FAIL: RSS report header is invalid" >&2
  exit 1
fi

stats=$(awk '
  NR > 1 {
    if ($1 !~ /^[0-9]+$/ || $2 !~ /^[1-9][0-9]*$/ || $3 !~ /^[1-9][0-9]*$/) {
      invalid=1
      next
    }
    count++
    pid[$2]=1
    if (count == 1) {
      first_elapsed=$1
      previous=$1
    } else {
      if ($1 <= previous) invalid=1
      gap=$1-previous
      if (gap > max_gap) max_gap=gap
      previous=$1
    }
    last_elapsed=$1
    if ($1 >= 300) {
      warm_count++
      sx += $1
      sy += $3
      sxx += $1*$1
      sxy += $1*$3
    }
  }
  END {
    denominator=warm_count*sxx-sx*sx
    slope=0
    if (warm_count > 1 && denominator != 0) {
      slope=(warm_count*sxy-sx*sy)/denominator*3600
    }
    printf "%d\t%d\t%d\t%d\t%d\t%d\t%.6f\n", invalid, count,
      length(pid), first_elapsed, last_elapsed, max_gap, slope
  }
' "$REPORT")

IFS=$'\t' read -r invalid count pid_count first_elapsed last_elapsed max_gap slope <<< "$stats"
if [[ "$count" -eq 0 ]]; then
  echo "FAIL: RSS report contains no valid samples" >&2
  exit 1
fi
if [[ "$invalid" != "0" ]]; then
  echo "FAIL: RSS report contains invalid or non-increasing samples" >&2
  exit 1
fi
if [[ "$pid_count" -ne 1 ]]; then
  echo "FAIL: RSS samples contain pid_count=$pid_count, expected 1" >&2
  exit 1
fi
if [[ "$first_elapsed" -ne 0 ]]; then
  echo "FAIL: RSS sampling did not begin at elapsed 0s" >&2
  exit 1
fi
required_floor=$(awk -v required="$REQUIRED_ELAPSED_SECONDS" -v tolerance="$ELAPSED_TOLERANCE_SECONDS" '
  BEGIN {
    delta=required-tolerance
    if (delta <= 0) {
      print 0
      exit
    }
    floor=int(delta)
    if (delta > floor) floor++
    print floor
  }
')
if (( last_elapsed < required_floor )); then
  echo "FAIL: RSS sampling ended at ${last_elapsed}s before required ${required_floor}s" >&2
  exit 1
fi

expected_samples=$((last_elapsed + 1))
coverage=$(awk -v actual="$count" -v expected="$expected_samples" '
  BEGIN { printf "%.6f", actual*100/expected }
')
if ! awk -v actual="$coverage" -v minimum="$MIN_COVERAGE_PERCENT" '
  BEGIN { exit !(actual >= minimum) }
'; then
  echo "FAIL: RSS sample coverage ${coverage}% is below ${MIN_COVERAGE_PERCENT}%" >&2
  exit 1
fi
if (( max_gap > MAX_GAP_SECONDS )); then
  echo "FAIL: RSS max sample gap ${max_gap}s exceeds ${MAX_GAP_SECONDS}s" >&2
  exit 1
fi
if (( last_elapsed < MIN_TREND_ELAPSED_SECONDS )); then
  echo "PASS: RSS sampling gate pid_count=${pid_count} samples=${count}/${expected_samples} coverage=${coverage}% max_gap=${max_gap}s; trend skipped below ${MIN_TREND_ELAPSED_SECONDS}s"
  exit 0
fi

median_for_range() {
  local start=$1
  local end=$2
  awk -v start="$start" -v end="$end" '
    NR > 1 && $1 >= start && $1 <= end { print $3 }
  ' "$REPORT" | sort -n | awk '
    { values[NR]=$1 }
    END {
      if (NR == 0) exit 1
      if (NR % 2) print values[(NR+1)/2]
      else printf "%.1f\n", (values[NR/2]+values[NR/2+1])/2
    }
  '
}

first_median=$(median_for_range 300 599)
last_window_start=$((last_elapsed - 299))
last_median=$(median_for_range "$last_window_start" "$last_elapsed")
median_growth=$(awk -v first="$first_median" -v last="$last_median" '
  BEGIN { printf "%.1f", last-first }
')
if ! awk -v actual="$median_growth" -v maximum="$MAX_MEDIAN_GROWTH_KB" '
  BEGIN { exit !(actual <= maximum) }
'; then
  echo "FAIL: RSS five-minute median growth ${median_growth}KB exceeds ${MAX_MEDIAN_GROWTH_KB}KB" >&2
  exit 1
fi
if ! awk -v actual="$slope" -v maximum="$MAX_SLOPE_KB_PER_HOUR" '
  BEGIN { exit !(actual <= maximum) }
'; then
  echo "FAIL: RSS slope ${slope}KB/h exceeds ${MAX_SLOPE_KB_PER_HOUR}KB/h" >&2
  exit 1
fi

echo "PASS: RSS gate pid_count=${pid_count} samples=${count}/${expected_samples} coverage=${coverage}% max_gap=${max_gap}s first5m_median=${first_median}KB last5m_median=${last_median}KB median_growth=${median_growth}KB slope=${slope}KB/h"
