#!/usr/bin/env bash
# Exercise the real soak script, with build/process fixtures instead of Swift.
set -euo pipefail
root_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/bin"
export SOAK_TEST_BIN="$fixture_dir/bin"
export SOAK_TEST_DIR="$fixture_dir"
cat > "$fixture_dir/bin/swift" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
    if [ "$argument" = --show-bin-path ]; then printf '%s\n' "$SOAK_TEST_BIN"; fi
done
SH
cat > "$fixture_dir/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixture_dir/bin/npm" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixture_dir/bin/gnostic" <<'SH'
#!/usr/bin/env bash
exec node "$SOAK_TEST_DIR/server.cjs" "$@"
SH
cat > "$fixture_dir/server.cjs" <<'JS'
const fs = require('fs');
const args = process.argv.slice(2);
const metrics = args[args.indexOf('--metrics-file') + 1];
const home = process.env.GNOSTIC_STATE_HOME || process.env.SOAK_TEST_DIR;
fs.mkdirSync(`${home}/timeline-journals`, {recursive: true});
fs.writeFileSync(`${home}/timeline-journals/fixture.jsonl`, 'journal\n');
const snapshot = JSON.stringify({
  inFlightTurns: process.env.SOAK_TEST_BAD_METRICS ? 'invalid' : 0, retainedTimelineCount: 1,
  retainedIdentityCount: Number(process.env.SOAK_TEST_IDENTITIES || 1),
  retainedCompletedCount: Number(process.env.SOAK_TEST_COMPLETED || 1),
  retainedTombstoneCount: 0, retainedCompletedBytes: 10,
  identityCapacity: 2, completedCapacity: 2,
});
function writeMetrics() {
  fs.writeFileSync(`${metrics}.tmp`, snapshot);
  fs.renameSync(`${metrics}.tmp`, metrics);
}
if (!process.env.SOAK_TEST_NO_METRICS) {
  writeMetrics();
  if (!process.env.SOAK_TEST_STALE_METRICS) {
    const cadence = Math.max(1000, Number(args[args.indexOf('--metrics-interval') + 1]) * 1000);
    setInterval(writeMetrics, Number(process.env.SOAK_TEST_METRICS_CADENCE_MS || cadence));
  }
}
console.log('gnostic serve online');
setInterval(() => {}, 1000);
JS
cat > "$fixture_dir/bin/gnostic-soak-driver" <<'SH'
#!/usr/bin/env bash
if [ "${SOAK_TEST_NO_TURNS:-0}" = 1 ]; then exit 0; fi
printf 'soak turn 1 ok chars=10 replayed=false duration_ms=1.5\n'
if [ "${SOAK_TEST_DRIVER_LATE_FAIL:-0}" = 1 ]; then sleep 0.5; echo fatal >&2; exit 9; fi
if [ "${SOAK_TEST_DRIVER_FAIL:-0}" = 1 ]; then echo fatal >&2; exit 9; fi
while :; do sleep 1; done
SH
export SOAK_TEST_SLEEP
SOAK_TEST_SLEEP=$(command -v sleep)
cat > "$fixture_dir/bin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${SOAK_TEST_NO_METRICS:-0}" = 1 ] && [ "${1:-}" = 0.5 ]; then exit 0; fi
exec "$SOAK_TEST_SLEEP" "$@"
SH
chmod +x "$fixture_dir/bin/"*
failures=0
run_case() {
    local name=$1 expected=$2 status=0
    shift 2
    env PATH="$fixture_dir/bin:$PATH" SOAK_DURATION_SECONDS=1 \
        SOAK_SAMPLE_INTERVAL_SECONDS=0.1 SOAK_ARTIFACT_ROOT="$fixture_dir/artifacts-$name" \
        SOAK_MAX_RSS_KB=1048576 SOAK_MAX_THREADS=512 \
        "$@" bash "$root_dir/Scripts/soak.sh" > "$fixture_dir/$name.log" 2>&1 || status=$?
    if [ "$status" != "$expected" ]; then
        echo "FAIL: soak $name expected status $expected, got $status" >&2
        tail -8 "$fixture_dir/$name.log" >&2
        failures=$((failures + 1))
    fi
}
run_case healthy 0
run_case rss 1 SOAK_MAX_RSS_KB=1
run_case threads 2 SOAK_MAX_THREADS=1
run_case identities 3 SOAK_TEST_IDENTITIES=3
run_case completed 4 SOAK_TEST_COMPLETED=3
run_case invalid-metrics 7 SOAK_TEST_BAD_METRICS=1
run_case driver-failure 6 SOAK_TEST_DRIVER_FAIL=1
run_case late-driver-failure 6 SOAK_TEST_DRIVER_LATE_FAIL=1 SOAK_DURATION_SECONDS=2 SOAK_SAMPLE_INTERVAL_SECONDS=3
run_case stale-metrics 7 SOAK_TEST_STALE_METRICS=1 SOAK_DURATION_SECONDS=5
run_case healthy-fast-samples 0 SOAK_DURATION_SECONDS=3 SOAK_TEST_METRICS_CADENCE_MS=1200
run_case no-turns 5 SOAK_TEST_NO_TURNS=1
run_case missing-metrics 7 SOAK_TEST_NO_METRICS=1
artifact=$(find "$fixture_dir/artifacts-healthy" -mindepth 1 -maxdepth 1 -type d | head -1)
if [ -z "$artifact" ] || [ ! -r "$artifact/samples.tsv" ] || [ ! -r "$artifact/driver.log" ] ||
   [ "$(cat "$artifact/status.txt" 2>/dev/null)" != 0 ] ||
   ! awk -F'\t' 'NF != 13 || $12 < 1 || $13 < 8 { exit 1 }' "$artifact/samples.tsv" ||
   ! grep -q duration_ms= "$artifact/driver.log" ||
   ! cmp -s "$root_dir/Package.resolved" "$artifact/Package.resolved"; then
    echo 'FAIL: successful soak did not retain complete evidence' >&2
    failures=$((failures + 1))
fi
failed_artifact=$(find "$fixture_dir/artifacts-rss" -mindepth 1 -maxdepth 1 -type d | head -1)
if [ "$(cat "$failed_artifact/status.txt" 2>/dev/null)" != 1 ]; then
    echo 'FAIL: failed soak did not retain its failing status' >&2
    failures=$((failures + 1))
fi
[ "$failures" -eq 0 ] || exit 1
echo '14 soak harness checks passed'
