#!/usr/bin/env bash
#
# install-test-ca-on-simulator.sh — trust the fixture CA in one simulator.
#
# Usage:
#   install-test-ca-on-simulator.sh <simulator-uuid> <ca-cert.pem>
#
# The first argument must be one exact 36-character simulator UUID. Aliases
# such as `booted`, names, `latest`, and partial UUIDs are rejected; the UUID
# must occur exactly once in `simctl list devices`. This is intentionally
# explicit: never install the fixture CA into a host keychain or an
# unspecified simulator.
#
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <simulator-uuid> <ca-cert.pem>" >&2
    exit 2
fi

device="$1"
ca_cert="$2"
if [[ "${device}" == "booted" ]]; then
    echo "refusing simulator alias 'booted'; pass an explicit UUID" >&2
    exit 2
fi
if [[ ! "${device}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "simulator must be an explicit UUID (aliases and partial UUIDs are refused)" >&2
    exit 2
fi
if [[ ! -f "${ca_cert}" ]]; then
    echo "CA certificate not found" >&2
    exit 1
fi

xcrun_bin="$(command -v xcrun || true)"
if [[ -z "${xcrun_bin}" ]]; then
    echo "xcrun is required" >&2
    exit 1
fi

device_list="$(${xcrun_bin} simctl list devices 2>/dev/null)" || {
    echo "could not query simulator devices with simctl" >&2
    exit 1
}
match_count="$(printf '%s\n' "${device_list}" | awk -v wanted="${device}" '
    index($0, "(" wanted ")") { count++ }
    END { print count + 0 }
')"
if [[ "${match_count}" != "1" ]]; then
    echo "simulator UUID must match exactly one device in simctl list devices" >&2
    exit 1
fi

# `simctl keychain add-root-cert` changes only the selected simulator's trust
# store. The explicit UUID was checked above; no alias is accepted.
"${xcrun_bin}" simctl keychain "${device}" add-root-cert "${ca_cert}"
