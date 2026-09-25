#!/usr/bin/env bash

set -euo pipefail

cd /workspace
stage_dir=.testing/rlm-scenario-stage0
mkdir -p "$stage_dir" Documentation/Experiments
suite_results="$stage_dir/fixture-suites.json"
rm -f "$suite_results"

swift_flags=(--cache-path /workspace/.swiftpm-cache --disable-automatic-resolution --build-system native --quiet -Xswiftc -warnings-as-errors)

run_suite() {
    local name=$1
    local filter=$2
    local log="$stage_dir/${name}.log"
    swift test "${swift_flags[@]}" --filter "$filter" 2>&1 | tee "$log"
    node - "$suite_results" "$name" "$filter" "$log" <<'NODE'
const fs = require("node:fs");
const crypto = require("node:crypto");

const [outputPath, name, filter, logPath] = process.argv.slice(2);
const log = fs.readFileSync(logPath);
const match = log.toString("utf8").match(/Test run with ([1-9][0-9]*) tests in ([1-9][0-9]*) suites?/);
if (!match) {
  process.stderr.write(`No tests executed for ${name} (${filter})\n`);
  process.exit(1);
}

const results = fs.existsSync(outputPath) ? JSON.parse(fs.readFileSync(outputPath, "utf8")) : [];
results.push({
  suite: name,
  filter,
  tests: Number(match[1]),
  suites: Number(match[2]),
  logSHA256: crypto.createHash("sha256").update(log).digest("hex"),
});
fs.writeFileSync(outputPath, `${JSON.stringify(results, null, 2)}\n`);
NODE
}

# M11: adversarial Scheme and sandbox-denial fixtures owned by #178/#179.
run_suite m11-guile-sandbox GnosticRLMGuileTests.RLMGuileSandboxDenialTests
run_suite m11-chibi-sandbox GnosticRLMChibiTests.RLMChibiSandboxDenialTests

# M12: executor-local loop/heap/recursion tests and cross-executor stress parity.
run_suite m12-guile-session GnosticRLMGuileTests.RLMGuileWorkerSessionTests
run_suite m12-chibi-session GnosticRLMChibiTests.RLMChibiWorkerSessionTests
run_suite m12-worker-parity GnosticRLMWorkerParityTests.RLMWorkerWireParityTests

bin=$(swift build "${swift_flags[@]}" --show-bin-path --product gnostic-rlm-scenario)/gnostic-rlm-scenario
test -x "$bin"
GNOSTIC_SCENARIO_ROOT=/workspace "$bin" > "$stage_dir/scenario.json"

node - "$stage_dir/scenario.json" "$suite_results" Documentation/Experiments/rlm-scenario-stage0.json <<'NODE'
const fs = require("node:fs");

const [scenarioPath, suitesPath, outputPath] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(scenarioPath, "utf8"));
const suites = JSON.parse(fs.readFileSync(suitesPath, "utf8"));
const m11 = suites.filter(({ suite }) => suite.startsWith("m11-"));
const m12 = suites.filter(({ suite }) => suite.startsWith("m12-"));

if (report.rows.length !== 12) {
  throw new Error(`Expected 12 scenario rows, got ${report.rows.length}`);
}
for (const row of report.rows) {
  const arms = [row.scripted, row.guile, row.chibi];
  if (arms.some(({ status, outcome }) => status !== "measured" || outcome !== "completed")) {
    throw new Error(`${row.id} did not complete on every Stage 0 arm`);
  }
  if (row.scripted.semanticDigest !== row.guile.semanticDigest || row.guile.semanticDigest !== row.chibi.semanticDigest) {
    throw new Error(`${row.id} semantic result digests differ across executors`);
  }
  if (row.guile.repairs !== 1 || row.chibi.repairs !== 1) {
    throw new Error(`${row.id} did not record the injected recoverable repair on both workers`);
  }
}
if (m11.length !== 2 || m12.length !== 3) {
  throw new Error(`Expected 2 M11 and 3 M12 suite records; got ${m11.length} and ${m12.length}`);
}

report.outcome = "stage-0-no-spend-complete";
report.validationEvidence = {
  M11: { status: "passed", suites: m11 },
  M12: { status: "passed", suites: m12 },
};
fs.writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`);
NODE

printf 'Wrote %s\n' Documentation/Experiments/rlm-scenario-stage0.json
