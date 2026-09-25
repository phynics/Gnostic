#!/usr/bin/env bash

# Validates the #354 live-stage handoff without contacting a provider.
#
# The live stages need a configured Positronic Ascendant and spend money. Run
# this first: it synthesises a throwaway Ollama-backed manifest, runs the
# scenario's dry-run path inside the pinned image, and fails unless the run
# reaches the dry-run stop. Ollama is used because it needs no API key; the
# dry run never dials it.
#
# Invoked by `make scenario-live-preflight`, which supplies the container and
# build environment. Run the script directly only from that target.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# One fixed, version-4 Ascendant identity so the generated manifest is valid
# and the dry run always resolves the same resources.
ascendant=a21d0000-0000-4000-8000-000000000002
stage=${STAGE:-pilot}
if [[ "$stage" != "pilot" && "$stage" != "matrix" ]]; then
    echo "STAGE must be pilot or matrix, got: $stage" >&2
    exit 2
fi
# The pilot needs no --pilot artifact; the matrix does, so a matrix dry run is
# not a self-contained preflight.
if [[ "$stage" != "pilot" ]]; then
    echo "scenario-live-preflight only validates the pilot handoff" >&2
    exit 2
fi

scratch=$(mktemp -d)
log="$scratch/dry-run.log"
trap 'rm -rf "$scratch"' EXIT INT TERM

cat > "$scratch/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "broker": { "host": "localhost", "port": 1883, "namespace": "gnostic" },
  "node": { "id": "a21d0000-0000-4000-8000-000000000001", "kind": "node", "approvalMode": "auto", "logLevel": "info" },
  "ascendants": [
    {
      "id": "a21d0000-0000-4000-8000-000000000002",
      "kind": "positronic",
      "name": "DryRun",
      "description": "",
      "metadata": {},
      "backend": { "kind": "positronic", "schemaVersion": 1, "settings": { "provider": "ollama", "model": "llama3" }, "secrets": {} },
      "defaultTimelineID": "a21d0000-0000-4000-8000-000000000003"
    }
  ],
  "timelines": [
    { "id": "a21d0000-0000-4000-8000-000000000003", "kind": "timeline", "title": "DryRun", "operatingAscendantID": "a21d0000-0000-4000-8000-000000000002", "flags": [], "attachments": [] }
  ],
  "workspaces": []
}
JSON

args="--stage ${stage} --ascendant ${ascendant}"

if ! CONFIG="$scratch/manifest.json" ARGS="$args" \
        bash "$repo_root/Scripts/run-rlm-scenario-live.sh" >"$log" 2>&1; then
    cat "$log" >&2
    echo "Live-stage dry run failed." >&2
    exit 1
fi

cat "$log"
grep -Fq "Preflight: every selected executor started and shut down cleanly." "$log"
grep -Fq "Dry run: no provider was contacted." "$log"
printf '%s\n' "Live-stage dry run OK: executors start and no provider is contacted."
