#!/usr/bin/env python3
"""Validate raw harness evidence and compute TLS/SLS relative metrics."""

import argparse
import json
import math
import os
import statistics


LIMIT = 1.20


def load_json(path):
    with open(path, "r", encoding="utf-8") as source:
        return json.load(source)


def percentile_nearest_rank(values, percentile):
    ordered = sorted(values)
    index = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[index]


def read_process_samples(path, start_ms, end_ms):
    samples = []
    with open(path, "r", encoding="ascii") as source:
        header = source.readline().strip().split("\t")
        expected = ["epoch_ms", "cpu_percent", "rss_kb"]
        if header != expected:
            raise ValueError("unexpected process sample header")
        for line in source:
            fields = line.strip().split("\t")
            if len(fields) != 3:
                continue
            epoch_ms = int(fields[0])
            if start_ms <= epoch_ms <= end_ms:
                cpu = float(fields[1])
                rss = int(fields[2])
                if cpu < 0 or rss <= 0:
                    raise ValueError("invalid process sample value")
                samples.append((cpu, rss))
    if not samples:
        raise ValueError("no process samples overlap the measurement window")
    return samples


def validate_run(run_dir):
    app = load_json(os.path.join(run_dir, "app-result.json"))
    server = load_json(os.path.join(run_dir, "server-stats.json"))
    failures = []
    if app.get("status") != "completed":
        failures.append("app status is not completed")
    fixed_contract = {
        "logicalBytesPerLog": 1024,
        "fieldCount": 10,
        "compression": "lz4",
        "sendConcurrency": 1,
        "batchMaxLogCount": 1024,
        "batchMaxRawBytes": 1024 * 1024,
        "batchLingerMilliseconds": 3000,
    }
    for field, expected in fixed_contract.items():
        if app.get(field) != expected:
            failures.append("%s differs from the fixed workload" % field)
    if app.get("sdk") not in ("tls", "sls"):
        failures.append("unknown SDK")
    if app.get("mode") not in ("memory", "persistent"):
        failures.append("unknown storage mode")
    if not isinstance(app.get("rate"), int) or app.get("rate", 0) <= 0:
        failures.append("invalid rate")
    latencies = app.get("latenciesNanoseconds", [])
    if len(latencies) != app.get("expectedMeasuredAdmissions"):
        failures.append("latency sample count differs from expected measured admissions")
    input_construction_latencies = app.get(
        "inputConstructionLatenciesNanoseconds", [])
    if app.get("schemaVersion", 1) >= 2 and \
            len(input_construction_latencies) != app.get("expectedMeasuredAdmissions"):
        failures.append(
            "input construction sample count differs from expected measured admissions")
    if app.get("admissionSuccess") != app.get("expectedTotalAdmissions"):
        failures.append("total admission success differs from expected")
    if app.get("admissionFailure") != 0:
        failures.append("admission failures are non-zero")
    if app.get("measurementAdmissionSuccess") != app.get("expectedMeasuredAdmissions"):
        failures.append("measurement admission success differs from expected")
    if app.get("measurementAdmissionFailure") != 0:
        failures.append("measurement admission failures are non-zero")
    if app.get("terminalFailure") != 0:
        failures.append("terminal failures are non-zero")
    if not isinstance(app.get("terminalSuccess"), int) or app.get("terminalSuccess", 0) <= 0:
        failures.append("no successful terminal callback was observed")
    if server.get("dataRequestCount") != app.get("terminalSuccess"):
        failures.append("server data request count differs from terminal success callbacks")
    if server.get("tlsRequestCount", 0) + server.get("slsRequestCount", 0) != \
            server.get("dataRequestCount"):
        failures.append("server split request counters do not sum to total")
    if server.get("bodyBytes", 0) <= 0:
        failures.append("server observed no request body bytes")
    if app.get("terminalRawBytes", 0) <= 0:
        failures.append("terminal callbacks reported no raw bytes")
    if app.get("sdk") == "tls" and server.get("slsRequestCount") != 0:
        failures.append("TLS run observed an SLS wire path")
    if app.get("sdk") == "sls" and server.get("tlsRequestCount") != 0:
        failures.append("SLS run observed a TLS wire path")
    if app.get("sdk") == "tls" and app.get("lifecycleClose") != "success":
        failures.append("TLS close did not succeed")
    if app.get("sdk") == "sls" and app.get("lifecycleClose") != \
            "skipped_known_sls_4_3_4_destroy_uaf":
        failures.append("SLS lifecycle boundary is not explicitly classified")
    if failures:
        raise ValueError("; ".join(failures))

    process = read_process_samples(
        os.path.join(run_dir, "process-samples.tsv"),
        app["measurementStartEpochMilliseconds"],
        app["measurementEndEpochMilliseconds"],
    )
    return {
        "runID": app["runID"],
        "sdk": app["sdk"],
        "mode": app["mode"],
        "rate": app["rate"],
        "p99InputConstructionMicroseconds": (
            percentile_nearest_rank(input_construction_latencies, 0.99) / 1000.0
            if input_construction_latencies else None),
        "p99AddMicroseconds": percentile_nearest_rank(latencies, 0.99) / 1000.0,
        "meanCPUPercent": statistics.fmean(item[0] for item in process),
        "peakRSSKiB": max(item[1] for item in process),
        "measurementSamples": len(process),
        "admissionCount": app["measurementAdmissionSuccess"],
        "terminalSuccess": app["terminalSuccess"],
        "serverRequestCount": server["dataRequestCount"],
        "serverBodyBytes": server["bodyBytes"],
        "terminalRawBytes": app["terminalRawBytes"],
        "lifecycleClose": app["lifecycleClose"],
    }


def ratio(numerator, denominator):
    if numerator is None or denominator is None or denominator == 0:
        return None
    return numerator / denominator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--output-markdown", required=True)
    parser.add_argument("--enforce-gate", action="store_true")
    args = parser.parse_args()

    runs = []
    run_ids = set()
    for name in sorted(os.listdir(args.input_dir)):
        run_dir = os.path.join(args.input_dir, name)
        if os.path.isdir(run_dir) and os.path.isfile(os.path.join(run_dir, "app-result.json")):
            try:
                run = validate_run(run_dir)
                if run["runID"] in run_ids:
                    raise ValueError("duplicate runID")
                run_ids.add(run["runID"])
                runs.append(run)
            except Exception as error:
                raise SystemExit("%s: %s" % (name, error))
    if not runs:
        raise SystemExit("no completed run evidence found")

    grouped = {}
    for run in runs:
        key = (run["mode"], run["rate"], run["sdk"])
        grouped.setdefault(key, []).append(run)

    comparisons = []
    workload_keys = sorted({(run["mode"], run["rate"]) for run in runs})
    gate_passed = True
    for mode, rate in workload_keys:
        values = {}
        for sdk in ("tls", "sls"):
            sdk_runs = grouped.get((mode, rate, sdk), [])
            if not sdk_runs:
                raise SystemExit("missing %s runs for %s/%s" % (sdk, mode, rate))
            construction_values = [
                run["p99InputConstructionMicroseconds"] for run in sdk_runs
                if run["p99InputConstructionMicroseconds"] is not None]
            values[sdk] = {
                "runCount": len(sdk_runs),
                "medianP99InputConstructionMicroseconds": (
                    statistics.median(construction_values)
                    if len(construction_values) == len(sdk_runs) else None),
                "medianP99AddMicroseconds": statistics.median(
                    run["p99AddMicroseconds"] for run in sdk_runs),
                "medianMeanCPUPercent": statistics.median(
                    run["meanCPUPercent"] for run in sdk_runs),
                "medianPeakRSSKiB": statistics.median(
                    run["peakRSSKiB"] for run in sdk_runs),
            }
        if values["tls"]["runCount"] != values["sls"]["runCount"]:
            raise SystemExit("TLS/SLS run counts differ for %s/%s" % (mode, rate))
        ratios = {
            "inputConstructionP99": ratio(
                values["tls"]["medianP99InputConstructionMicroseconds"],
                values["sls"]["medianP99InputConstructionMicroseconds"]),
            "p99Add": ratio(
                values["tls"]["medianP99AddMicroseconds"],
                values["sls"]["medianP99AddMicroseconds"]),
            "cpu": ratio(
                values["tls"]["medianMeanCPUPercent"],
                values["sls"]["medianMeanCPUPercent"]),
            "rss": ratio(
                values["tls"]["medianPeakRSSKiB"],
                values["sls"]["medianPeakRSSKiB"]),
        }
        comparison_passed = all(
            ratios[name] is not None and ratios[name] <= LIMIT
            for name in ("p99Add", "cpu", "rss"))
        gate_passed = gate_passed and comparison_passed
        comparisons.append({
            "mode": mode,
            "rate": rate,
            "tls": values["tls"],
            "sls": values["sls"],
            "tlsToSLSRatios": ratios,
            "gatePassed": comparison_passed,
        })

    summary = {
        "schemaVersion": 2,
        "sourceBuildBaseline": "AliyunLogProducer 4.3.4 with only Simulator EXCLUDED_ARCHS cleared",
        "metricBoundary": {
            "latency": "public add call only; log object creation excluded",
            "inputConstruction": "per-log public input object construction, reported separately and not gated",
            "cpu": "mean host ps process percent during app measurement epoch; includes input construction, SDK admission, and background work",
            "rss": "peak host process RSS KiB during app measurement epoch",
            "delivery": "admission, terminal callback, and server request counters are separate",
        },
        "limit": LIMIT,
        "runCount": len(runs),
        "runs": runs,
        "comparisons": comparisons,
        "gatePassed": gate_passed,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.output_json)), exist_ok=True)
    with open(args.output_json, "w", encoding="utf-8") as output:
        json.dump(summary, output, indent=2, sort_keys=True)
        output.write("\n")

    lines = [
        "# TLS versus SLS 4.3.4 performance summary",
        "",
        "SLS is source-built with only its arm64 Simulator exclusion cleared; this is not official package evidence.",
        "",
        "| Mode | Rate | Input build P99 ratio | Add P99 ratio | CPU ratio | RSS ratio | Gate <= 1.20 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for item in comparisons:
        ratios = item["tlsToSLSRatios"]
        rendered = ["n/a" if ratios[name] is None else "%.3f" % ratios[name]
                    for name in ("inputConstructionP99", "p99Add", "cpu", "rss")]
        lines.append("| %s | %d | %s | %s | %s | %s | %s |" % (
            item["mode"], item["rate"], rendered[0], rendered[1], rendered[2], rendered[3],
            "PASS" if item["gatePassed"] else "FAIL"))
    lines.extend([
        "",
        "Admission counts, terminal callbacks, and server request counts were validated independently; request count alone is not treated as per-log delivery proof.",
        "",
    ])
    with open(args.output_markdown, "w", encoding="utf-8") as output:
        output.write("\n".join(lines))

    if args.enforce_gate and not gate_passed:
        raise SystemExit("relative performance gate failed")


if __name__ == "__main__":
    main()
