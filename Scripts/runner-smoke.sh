#!/usr/bin/env bash

# Smoke-tests the standalone runner's composition (GNO-PLAT-012, #446).
#
# The runner composes through GnosticHost, so it must host every backend kind
# `gnostic serve` has. This script proves the shape twice: once with the
# bundled Positronic default graph, and once with a manifest that selects the
# non-Positronic Letta backend. Both runs must come online.
#
# Invoked by `make runner-smoke`, which supplies the container and build
# environment. Run the script directly only from that target.

set -euo pipefail

cd /workspace

swift_flags=(--cache-path /workspace/.swiftpm-cache --disable-automatic-resolution --build-system native --quiet -Xswiftc -warnings-as-errors)

# The pre-#446 startup path carried a fixture scenario and a private error
# type. Neither may return.
test ! -e Sources/GnosticRunner/FixtureScenario.swift
test ! -e Sources/GnosticRunner/RunnerError.swift

# The runner may not link a native PositronicKit product directly; it reaches
# backends through GnosticHost.
package=$(swift package dump-package "${swift_flags[@]}")
printf '%s\n' "$package" | node -e '
let data = "";
process.stdin.on("data", (chunk) => { data += chunk; });
process.stdin.on("end", () => {
    const target = JSON.parse(data).targets.find(({ name }) => name === "GnosticRunner");
    const dependencies = JSON.stringify(target?.dependencies ?? []);
    if (!target || /PositronicKit|PKContracts/.test(dependencies)) process.exit(1);
});
'

bin=$(swift build "${swift_flags[@]}" --product gnostic-runner --show-bin-path)/gnostic-runner
test -x "$bin"

help=$("$bin" --help 2>&1)
status=$?
printf '%s\n' "$help"
test "$status" -eq 0
! printf '%s\n' "$help" | grep -F -- "--scenario"

pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT INT TERM
runner_log="$scratch/runner.log"

# Starts the runner with the given arguments and waits for its online line.
run_until_online() {
    local label=$1
    shift
    : > "$runner_log"
    stdbuf -oL "$@" >"$runner_log" 2>&1 &
    local runner_pid=$!
    local ready=1
    for _ in $(seq 1 30); do
        if grep -F "gnostic-runner online at" "$runner_log" >/dev/null 2>&1; then
            ready=0
            break
        fi
        if ! kill -0 "$runner_pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    cat "$runner_log"
    if [ "$ready" -ne 0 ]; then
        echo "runner did not come online for: $label" >&2
        return 1
    fi
}

# Default graph: the bundled Positronic backend from NodeManifest.makeDefault.
run_until_online "positronic default" \
    "$bin" --host 127.0.0.1 --port 1883 --namespace gnostic-smoke

# Non-Positronic case: a manifest that selects the Letta backend. Letta builds
# its transport without dialing the server, so the runner can host it offline.
# The kind is registered only in GnosticHost's composition, so accepting this
# manifest exercises the shared composition root.
cat > "$scratch/letta.json" <<'JSON'
{
  "schemaVersion": 2,
  "broker": { "host": "127.0.0.1", "port": 1883, "namespace": "gnostic-smoke-letta" },
  "node": { "id": "e51d0000-0000-4000-8000-000000000001", "kind": "node", "approvalMode": "auto", "logLevel": "info" },
  "ascendants": [
    {
      "id": "e51d0000-0000-4000-8000-000000000002",
      "kind": "letta",
      "name": "Letta",
      "description": "",
      "metadata": {},
      "backend": {
        "kind": "letta",
        "schemaVersion": 1,
        "settings": { "serverURL": "http://127.0.0.1:8283", "model": "openai/test-model" },
        "secrets": {}
      },
      "defaultTimelineID": "e51d0000-0000-4000-8000-000000000003"
    }
  ],
  "timelines": [
    { "id": "e51d0000-0000-4000-8000-000000000003", "kind": "timeline", "title": "Letta", "operatingAscendantID": "e51d0000-0000-4000-8000-000000000002", "flags": [], "attachments": [] }
  ],
  "workspaces": []
}
JSON

run_until_online "non-Positronic Letta backend" \
    "$bin" --host 127.0.0.1 --port 1883 --namespace gnostic-smoke-letta --config "$scratch/letta.json"

# Module case: a manifest that selects the compiled-in Atlas module. Startup
# builds the descriptor's Positronic contribution and installs its terminal
# Turn observer, so accepting this manifest exercises the module seam in the
# runner executable, not only in tests (#449).
cat > "$scratch/atlas.json" <<'JSON'
{
  "schemaVersion": 2,
  "broker": { "host": "127.0.0.1", "port": 1883, "namespace": "gnostic-smoke-atlas" },
  "node": { "id": "e51d0000-0000-4000-8000-000000000101", "kind": "node", "approvalMode": "auto", "logLevel": "info" },
  "ascendants": [
    {
      "id": "e51d0000-0000-4000-8000-000000000102",
      "kind": "positronic",
      "name": "Atlas",
      "description": "",
      "metadata": {},
      "backend": {
        "kind": "positronic",
        "schemaVersion": 1,
        "settings": { "extensions": ["atlas"] },
        "secrets": {}
      },
      "defaultTimelineID": "e51d0000-0000-4000-8000-000000000103"
    }
  ],
  "timelines": [
    { "id": "e51d0000-0000-4000-8000-000000000103", "kind": "timeline", "title": "Atlas", "operatingAscendantID": "e51d0000-0000-4000-8000-000000000102", "flags": [], "attachments": [] }
  ],
  "workspaces": []
}
JSON

run_until_online "Atlas module" \
    "$bin" --host 127.0.0.1 --port 1883 --namespace gnostic-smoke-atlas --config "$scratch/atlas.json"

# RLM module case: a manifest that selects the compiled-in RLM module. Startup
# materializes the Positronic backend with the descriptor's bounded-analysis
# contribution. The contribution needs no live provider or Scheme worker to
# build, so accepting this manifest exercises the RLM descriptor seam in the
# runner executable, not only in tests (#450).
cat > "$scratch/rlm.json" <<'JSON'
{
  "schemaVersion": 2,
  "broker": { "host": "127.0.0.1", "port": 1883, "namespace": "gnostic-smoke-rlm" },
  "node": { "id": "e51d0000-0000-4000-8000-000000000201", "kind": "node", "approvalMode": "auto", "logLevel": "info" },
  "ascendants": [
    {
      "id": "e51d0000-0000-4000-8000-000000000202",
      "kind": "positronic",
      "name": "RLM",
      "description": "",
      "metadata": {},
      "backend": {
        "kind": "positronic",
        "schemaVersion": 1,
        "settings": { "extensions": ["rlm"] },
        "secrets": {}
      },
      "defaultTimelineID": "e51d0000-0000-4000-8000-000000000203"
    }
  ],
  "timelines": [
    { "id": "e51d0000-0000-4000-8000-000000000203", "kind": "timeline", "title": "RLM", "operatingAscendantID": "e51d0000-0000-4000-8000-000000000202", "flags": [], "attachments": [] }
  ],
  "workspaces": []
}
JSON

run_until_online "RLM module" \
    "$bin" --host 127.0.0.1 --port 1883 --namespace gnostic-smoke-rlm --config "$scratch/rlm.json"

echo "Gnostic runner smoke passed"
