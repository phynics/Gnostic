#!/usr/bin/env bash

set -euo pipefail

swift --version | grep -F "Swift version 6.4"
cargo --version
git --version
node --version
npm --version
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 18)) process.exit(1)'
guile --version | grep -F "GNU Guile) 3.0."
chibi-scheme -V | grep -F "chibi-scheme 0.12"
test "$(chibi-scheme -p '(+ 2 3)')" = "5"
bash /workspace/Scripts/test-rlm-limit-exec.sh /usr/local/bin/gnostic-rlm-limit-exec
test -w /workspace/.swiftpm-cache
mosquitto -c /etc/mosquitto/gnostic.conf -d
smoke_output=$(mktemp)
trap 'rm -f "$smoke_output"' EXIT INT TERM
mosquitto_pub -h 127.0.0.1 -t gnostic/smoke -m ready -r
mosquitto_sub -h 127.0.0.1 -t gnostic/smoke -C 1 -W 5 >"$smoke_output"
mosquitto_pub -h 127.0.0.1 -t gnostic/smoke -n -r
grep -Fx ready "$smoke_output"

echo "Gnostic container smoke passed"
