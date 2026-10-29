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
# Direct runs also require Linux /proc, mosquitto, node, and the pinned toolchain.
#
# Environment:
#   SOAK_DURATION_SECONDS       wall-clock duration (default 60)
#   SOAK_TURNS                  Turns the driver may run before the duration
#                               ends (default 1000000)
#   SOAK_TURN_INTERVAL_MS       delay between Turns (default 50)
#   SOAK_SAMPLE_INTERVAL_SECONDS  sampling cadence (default 2)
#   SOAK_MAX_RSS_KB             resident-size bound (default 1048576)
#   SOAK_MAX_THREADS            thread-count bound (default 512)
#   SOAK_ARTIFACT_ROOT          retained per-run evidence parent (.testing/soak)

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
swift_flags=("${swift_cache_args[@]}" --disable-automatic-resolution --build-system native --quiet -Xswiftc -warnings-as-errors)

artifact_root=${SOAK_ARTIFACT_ROOT:-"$repo_root/.testing/soak"}
mkdir -p "$artifact_root"
scratch=$(mktemp -d "$artifact_root/run-XXXXXXXX")
echo "Soak artifacts: $scratch"
serve_pid=""
driver_pid=""
stop_process() {
    local pid=$1
    [ -n "$pid" ] || return 0
    local status=0 sent_term=0 sent_kill=0
    if kill -TERM "$pid" 2>/dev/null; then sent_term=1; fi
    for _ in {1..50}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        if kill -KILL "$pid" 2>/dev/null; then sent_kill=1; fi
    fi
    wait "$pid" 2>/dev/null || status=$?
    if [ "$status" = 143 ] && [ "$sent_term" = 1 ]; then return 0; fi
    if [ "$status" = 137 ] && [ "$sent_kill" = 1 ]; then return 0; fi
    return "$status"
}
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_process "$driver_pid" || true
    stop_process "$serve_pid" || true
    printf '%s\n' "$status" > "$scratch/status.txt"
    echo "Soak artifacts retained: $scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${SWIFT_FLAGS:-}" ]; then read -r -a swift_flags <<< "$SWIFT_FLAGS"; fi
echo "Building the serve binary and soak driver…" >&2
swift build "${swift_flags[@]}" --product gnostic 2>&1 | tee "$scratch/build.log"
swift build "${swift_flags[@]}" --product gnostic-soak-driver 2>&1 | tee -a "$scratch/build.log"
bin_dir=$(swift build "${swift_flags[@]}" --show-bin-path)
serve_bin="$bin_dir/gnostic"
driver_bin="$bin_dir/gnostic-soak-driver"
test -x "$serve_bin" || { echo "missing gnostic at $serve_bin" >&2; exit 1; }
test -x "$driver_bin" || { echo "missing gnostic-soak-driver at $driver_bin" >&2; exit 1; }
cp Package.resolved "$scratch/Package.resolved"
printf '%s\n' "${GNOSTIC_BUILD_REVISION:-unknown}" > "$scratch/revision.txt"

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
GNOSTIC_STATE_HOME="$scratch/state" "$serve_bin" serve --config "$manifest" --metrics-file "$metrics" --metrics-interval "$sample_interval" \
    > "$serve_log" 2>&1 &
serve_pid=$!

for _ in $(seq 1 120); do
    grep -q "gnostic serve online" "$serve_log" 2>/dev/null && break
    kill -0 "$serve_pid" 2>/dev/null || { echo "serve exited during startup:" >&2; cat "$serve_log" >&2; exit 1; }
    sleep 0.5
done

test -r "$metrics" || {
    for _ in $(seq 1 120); do
        test -r "$metrics" && break
        kill -0 "$serve_pid" 2>/dev/null || { cat "$serve_log" >&2; exit 1; }
        sleep 0.5
    done
}
test -r "$metrics" || { echo "FAIL: serve produced no metrics" >&2; exit 7; }

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
            const fs = require("fs"), path = require("path");
            const maximumAge = Math.max(1, Number(process.argv[4])) * 3000;
            if (Date.now() - fs.statSync(process.argv[1]).mtimeMs > maximumAge) {
                console.error("Metrics snapshot is stale."); process.exit(7);
            }
            const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
            function bytes(directory) {
                if (!fs.existsSync(directory)) return 0;
                return fs.readdirSync(directory, {withFileTypes: true}).reduce((total, entry) => {
                    const file = path.join(directory, entry.name);
                    return total + (entry.isDirectory() ? bytes(file) : fs.statSync(file).size);
                }, 0);
            }
            const descriptors = fs.readdirSync(`/proc/${process.argv[2]}/fd`).length;
            const values = [m.inFlightTurns, m.retainedTimelineCount, m.retainedIdentityCount,
                m.retainedCompletedCount, m.retainedTombstoneCount, m.retainedCompletedBytes,
                m.identityCapacity, m.completedCapacity, descriptors, bytes(process.argv[3])];
            if (!values.every(value => Number.isSafeInteger(value) && value >= 0)) {
                console.error("Metrics snapshot contains invalid counters."); process.exit(7);
            }
            process.stdout.write(values.join("\t"));
        ' "$metrics" "$serve_pid" "$scratch/state/timeline-journals" "$sample_interval") || {
            echo "FAIL: invalid or stale soak metrics" >&2
            exit 7
        }
    else
        echo "FAIL: soak metrics disappeared" >&2
        exit 7
    fi
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "${rss_kb:-?}" "${threads:-?}" "$ledger" >> "$samples"
}

deadline=$(( $(date +%s) + duration ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sample
    kill -0 "$serve_pid" 2>/dev/null || { echo "serve exited during the soak:" >&2; cat "$serve_log" >&2; exit 1; }
    if [ -n "$driver_pid" ] && ! kill -0 "$driver_pid" 2>/dev/null; then
        if wait "$driver_pid"; then
            driver_pid=""
        else
            driver_pid=""
            echo "FAIL: the soak driver exited unsuccessfully" >&2
            tail -20 "$driver_log" >&2
            exit 6
        fi
    fi
    sleep "$sample_interval"
done
sample

if ! stop_process "$driver_pid"; then
    driver_pid=""
    echo "FAIL: the soak driver exited unsuccessfully" >&2
    tail -20 "$driver_log" >&2
    exit 6
fi
driver_pid=""
stop_process "$serve_pid"
serve_pid=""

turns_run=$(grep -c "soak turn .* ok" "$driver_log" 2>/dev/null || true)
driver_errors=$(grep -ic "error\|failed" "$driver_log" 2>/dev/null || true)

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
    NR == 1 { journal_first = $13 + 0 }
    { journal_last = $13 + 0; if ($12 + 0 > descriptor_max) descriptor_max = $12 + 0 }
    END {
        printf "  peak file descriptors %d\n", descriptor_max
        printf "  journal bytes       %d (growth %d)\n", journal_last, journal_last - journal_first
        printf "  peak RSS (KB)       %d\n", rss_max
        printf "  peak threads        %d\n", threads_max
        printf "  peak ledger         timelines=%d identities=%d completed=%d bytes=%d (capacities identities=%s completed=%s)\n",
            timeline_max, identity_max, completed_max, bytes_max, identity_capacity, completed_capacity
    }
' "$samples"

status=0
awk -v rss_max="$max_rss_kb" -v thread_max="$max_threads" -F'\t' '
    NF != 13 { status = 7; exit }
    { for (i = 1; i <= NF; i++) if ($i !~ /^[0-9]+$/) { status = 7; exit } }
    $2 + 0 > rss_max { status = 1; exit }
    $3 + 0 > thread_max { status = 2; exit }
    $6 + 0 > $10 + 0 { status = 3; exit }
    $7 + 0 > $11 + 0 { status = 4; exit }
    END { if (NR == 0) status = 7; exit status }
' "$samples" || status=$?

case "$status" in
    0) ;;
    1) echo "FAIL: peak RSS exceeded ${max_rss_kb} KB" >&2 ;;
    2) echo "FAIL: peak thread count exceeded ${max_threads}" >&2 ;;
    3) echo "FAIL: retained identified Turns exceeded capacity" >&2 ;;
    4) echo "FAIL: retained completed Turns exceeded capacity" >&2 ;;
    7) echo "FAIL: incomplete or invalid soak samples" >&2 ;;
esac
[ "$turns_run" -gt 0 ] || { echo "FAIL: the driver completed no Turns" >&2; status=5; }
[ "$driver_errors" -eq 0 ] || { echo "FAIL: the driver reported errors" >&2; status=6; }

if [ "$status" -ne 0 ]; then
    echo "Driver tail:" >&2
    tail -20 "$driver_log" >&2
    exit "$status"
fi
awk '
    /duration_ms=/ { for (i = 1; i <= NF; i++) if ($i ~ /^duration_ms=/) {
        split($i, value, "="); total += value[2]; count++; if (value[2] + 0 > peak) peak = value[2] + 0
    } }
    END { if (count > 0) printf "  Turn latency (ms)   mean=%.3f peak=%.3f samples=%d\n", total/count, peak, count }
' "$driver_log"
echo "Soak bounds held."
