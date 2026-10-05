#!/usr/bin/env bash

# Soak target (GNO-PLAT-062, #454).
#
# Runs `gnostic serve` with the deterministic ACP fixture agent and drives
# scripted Turns for a configurable duration. While it runs, it samples the
# serve process's resident size and thread count and the bounded Turn-ledger
# metrics `gnostic serve --metrics-file` emits, then fails when a configured
# bound is exceeded.
#
# Invoked by `make soak`, which supplies the container and build environment.
# Runnable directly where mosquitto and node are present.
#
# Environment:
#   SOAK_DURATION_SECONDS       wall-clock duration (default 60)
#   SOAK_TURNS                  Turns the driver may run before the duration
#                               ends (default 1000000)
#   SOAK_TURN_INTERVAL_MS       delay between Turns (default 50)
#   SOAK_SAMPLE_INTERVAL_SECONDS  sampling cadence (default 2)
#   SOAK_MAX_RSS_KB             resident-size bound (default 1048576)
#   SOAK_MAX_THREADS            thread-count bound (default 512)

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

duration=${SOAK_DURATION_SECONDS:-60}
turns=${SOAK_TURNS:-1000000}
turn_interval_ms=${SOAK_TURN_INTERVAL_MS:-50}
sample_interval=${SOAK_SAMPLE_INTERVAL_SECONDS:-2}
max_rss_kb=${SOAK_MAX_RSS_KB:-1048576}
max_threads=${SOAK_MAX_THREADS:-512}
turn_timeout=${SOAK_TURN_TIMEOUT_SECONDS:-30}
broker_host=${SOAK_BROKER_HOST:-127.0.0.1}
broker_port=${SOAK_BROKER_PORT:-1883}
namespace=${SOAK_NAMESPACE:-gnostic-soak}

swift_cache_args=()
if [ -d /workspace/.swiftpm-cache ]; then
    swift_cache_args=(--cache-path /workspace/.swiftpm-cache)
fi
swift_flags=("${swift_cache_args[@]}" --build-system native --quiet -Xswiftc -warnings-as-errors)

echo "Building the serve binary and soak driver…" >&2
swift build "${swift_flags[@]}" --product gnostic
swift build "${swift_flags[@]}" --product gnostic-soak-driver
bin_dir=$(swift build "${swift_flags[@]}" --show-bin-path)
serve_bin="$bin_dir/gnostic"
driver_bin="$bin_dir/gnostic-soak-driver"
test -x "$serve_bin" || { echo "missing gnostic at $serve_bin" >&2; exit 1; }
test -x "$driver_bin" || { echo "missing gnostic-soak-driver at $driver_bin" >&2; exit 1; }

scratch=$(mktemp -d)
serve_pid=""
driver_pid=""
cleanup() {
    [ -n "$driver_pid" ] && kill "$driver_pid" 2>/dev/null || true
    [ -n "$serve_pid" ] && kill -TERM "$serve_pid" 2>/dev/null || true
    rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

# The container's deterministic Mosquitto when present; otherwise a private
# anonymous listener for a direct run.
if ! pgrep mosquitto >/dev/null 2>&1; then
    if [ -f /etc/mosquitto/gnostic.conf ]; then
        mosquitto -c /etc/mosquitto/gnostic.conf -d
    else
        printf '%s\n' \
            "listener $broker_port $broker_host" \
            'allow_anonymous true' \
            'persistence false' \
            "log_dest file $scratch/mosquitto.log" \
            > "$scratch/mosquitto.conf"
        mosquitto -c "$scratch/mosquitto.conf" -d
    fi
fi

agent="$repo_root/Tests/Fixtures/ACPAgent/agent.mjs"
if [ ! -d "$repo_root/Tests/Fixtures/ACPAgent/node_modules" ]; then
    npm ci --prefix "$repo_root/Tests/Fixtures/ACPAgent" --cache "$scratch/npm-cache" >&2
fi

timeline_id=$(node -e 'process.stdout.write(crypto.randomUUID())')
ascendant_id=$(node -e 'process.stdout.write(crypto.randomUUID())')
node_id=$(node -e 'process.stdout.write(crypto.randomUUID())')
node_bin=$(command -v node)
manifest="$scratch/manifest.json"
metrics="$scratch/metrics.json"
state="$scratch/agent-sessions.json"
serve_log="$scratch/serve.log"
driver_log="$scratch/driver.log"
samples="$scratch/samples.tsv"

node - "$manifest" "$ascendant_id" "$timeline_id" "$node_id" "$agent" "$state" \
    "$broker_host" "$broker_port" "$namespace" "$node_bin" <<'JS'
const [path, ascendantId, timelineId, nodeId, agentPath, statePath, host, port, namespace, nodeBin] = process.argv.slice(2);
const manifest = {
  schemaVersion: 2,
  broker: { host, port: Number(port), namespace },
  node: { id: nodeId, kind: "node", approvalMode: "auto", logLevel: "warning" },
  ascendants: [{
    id: ascendantId,
    kind: "acp-client",
    name: "Soak fixture",
    description: "",
    metadata: {},
    backend: {
      kind: "acp-client",
      schemaVersion: 1,
      settings: {
        command: nodeBin,
        args: JSON.stringify([agentPath]),
        env: JSON.stringify({ GNOSTIC_ACP_FIXTURE_STATE: statePath }),
      },
      secrets: {},
    },
    defaultTimelineID: timelineId,
  }],
  timelines: [{
    id: timelineId,
    kind: "timeline",
    title: "Soak",
    operatingAscendantID: ascendantId,
    flags: [],
    attachments: [],
  }],
  workspaces: [],
};
require("fs").writeFileSync(path, JSON.stringify(manifest, null, 2));
JS

echo "Starting gnostic serve (namespace $namespace, duration ${duration}s)…" >&2
"$serve_bin" serve --config "$manifest" --metrics-file "$metrics" --metrics-interval "$sample_interval" \
    > "$serve_log" 2>&1 &
serve_pid=$!

for _ in $(seq 1 120); do
    grep -q "gnostic serve online" "$serve_log" 2>/dev/null && break
    kill -0 "$serve_pid" 2>/dev/null || { echo "serve exited during startup:" >&2; cat "$serve_log" >&2; exit 1; }
    sleep 0.5
done

echo "Driving Turns…" >&2
"$driver_bin" --host "$broker_host" --port "$broker_port" --namespace "$namespace" \
    --timeline "$timeline_id" --turns "$turns" --interval-ms "$turn_interval_ms" \
    --turn-timeout "$turn_timeout" > "$driver_log" 2>&1 &
driver_pid=$!

sample() {
    local rss_kb="?" threads="?"
    if [ -r "/proc/$serve_pid/status" ]; then
        rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$serve_pid/status" 2>/dev/null || echo "?")
        threads=$(awk '/^Threads:/ {print $2}' "/proc/$serve_pid/status" 2>/dev/null || echo "?")
    else
        rss_kb=$(ps -o rss= -p "$serve_pid" 2>/dev/null | tr -d ' ' || echo "?")
        threads=$(ps -M -p "$serve_pid" 2>/dev/null | wc -l | tr -d ' ' || echo "?")
    fi
    local ledger="-"
    if [ -r "$metrics" ]; then
        ledger=$(node -e '
            const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
            process.stdout.write([m.inFlightTurns, m.retainedTimelineCount, m.retainedIdentityCount,
                m.retainedCompletedCount, m.retainedTombstoneCount, m.retainedCompletedBytes,
                m.identityCapacity, m.completedCapacity].join("\t"));
        ' "$metrics" 2>/dev/null || echo "-")
    fi
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "${rss_kb:-?}" "${threads:-?}" "$ledger" >> "$samples"
}

deadline=$(( $(date +%s) + duration ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sample
    kill -0 "$serve_pid" 2>/dev/null || { echo "serve exited during the soak:" >&2; cat "$serve_log" >&2; exit 1; }
    sleep "$sample_interval"
done
sample

kill "$driver_pid" 2>/dev/null || true
wait "$driver_pid" 2>/dev/null || true
driver_pid=""
kill -TERM "$serve_pid" 2>/dev/null || true
wait "$serve_pid" 2>/dev/null || true
serve_pid=""

turns_run=$(grep -c "soak turn .* ok" "$driver_log" 2>/dev/null || true)
driver_errors=$(grep -c "error\|failed" "$driver_log" 2>/dev/null || true)

echo ""
echo "Soak summary"
echo "  duration            ${duration}s"
echo "  turns completed     $turns_run"
echo "  samples             $(( $(wc -l < "$samples") ))"
awk -F'\t' '
    NR == 1 { rss_max = $2 + 0; threads_max = $3 + 0 }
    $2 ~ /^[0-9]+$/ && $2 + 0 > rss_max { rss_max = $2 + 0 }
    $3 ~ /^[0-9]+$/ && $3 + 0 > threads_max { threads_max = $3 + 0 }
    $5 ~ /^[0-9]+$/ {
        if ($5 + 0 > timeline_max) timeline_max = $5 + 0
        if ($6 + 0 > identity_max) identity_max = $6 + 0
        if ($7 + 0 > completed_max) completed_max = $7 + 0
        if ($9 + 0 > bytes_max) bytes_max = $9 + 0
        identity_capacity = $10
        completed_capacity = $11
    }
    END {
        printf "  peak RSS (KB)       %d\n", rss_max
        printf "  peak threads        %d\n", threads_max
        printf "  peak ledger         timelines=%d identities=%d completed=%d bytes=%d (capacities identities=%s completed=%s)\n",
            timeline_max, identity_max, completed_max, bytes_max, identity_capacity, completed_capacity
    }
' "$samples"

status=0
awk -v rss_max="$max_rss_kb" -v thread_max="$max_threads" -F'\t' '
    $2 ~ /^[0-9]+$/ && $2 + 0 > rss_max { exit 1 }
    $3 ~ /^[0-9]+$/ && $3 + 0 > thread_max { exit 2 }
    $6 ~ /^[0-9]+$/ && $10 ~ /^[0-9]+$/ && $6 + 0 > $10 + 0 { exit 3 }
    $7 ~ /^[0-9]+$/ && $11 ~ /^[0-9]+$/ && $7 + 0 > $11 + 0 { exit 4 }
    END { exit 0 }
' "$samples" || status=$?

case "$status" in
    0) ;;
    1) echo "FAIL: peak RSS exceeded ${max_rss_kb} KB" >&2 ;;
    2) echo "FAIL: peak thread count exceeded ${max_threads}" >&2 ;;
    3) echo "FAIL: retained identified Turns exceeded capacity" >&2 ;;
    4) echo "FAIL: retained completed Turns exceeded capacity" >&2 ;;
esac
[ "$turns_run" -gt 0 ] || { echo "FAIL: the driver completed no Turns" >&2; status=5; }
[ "$driver_errors" -eq 0 ] || { echo "FAIL: the driver reported errors" >&2; status=6; }

if [ "$status" -ne 0 ]; then
    echo "Driver tail:" >&2
    tail -20 "$driver_log" >&2
    exit "$status"
fi
echo "Soak bounds held."
