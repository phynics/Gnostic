#!/usr/bin/env bash

set -euo pipefail

swift --version | grep -F "Swift version 6.3.3"
cargo --version
git --version
test -w /workspace/.swiftpm-cache
mosquitto -c /etc/mosquitto/gnostic.conf -d
smoke_output=$(mktemp)
trap 'rm -f "$smoke_output"' EXIT INT TERM
mosquitto_sub -h 127.0.0.1 -t gnostic/smoke -C 1 -W 5 >"$smoke_output" &
subscriber_pid=$!
mosquitto_pub -h 127.0.0.1 -t gnostic/smoke -m ready
wait "$subscriber_pid"
grep -Fx ready "$smoke_output"

echo "Gnostic container smoke passed"
