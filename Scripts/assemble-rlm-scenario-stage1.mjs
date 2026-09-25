// Assembles the #354 Stage 1 artifact (manifest §4 M13/M14, §8 Stage 1) from
// the macOS smoke's per-test xUnit reports and the launcher probes. Every
// containment claim names the tests or probes that back it; an unexpected
// failure or skip fails the run instead of being recorded as a result.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const argumentsByName = {};
for (let index = 2; index < process.argv.length; index += 2) {
  argumentsByName[process.argv[index].replace(/^--/, "")] = process.argv[index + 1];
}
const evidenceDirectory = argumentsByName.evidence;
const probesPath = argumentsByName.probes;
const outputPath = argumentsByName.output;
if (!evidenceDirectory || !probesPath || !outputPath) {
  throw new Error("usage: --evidence <dir> --probes <jsonl> --output <json>");
}

const sha256 = (buffer) => crypto.createHash("sha256").update(buffer).digest("hex");
const fileSHA256 = (filePath) => sha256(fs.readFileSync(filePath));
const environment = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
};

const suiteFilters = [
  "RLMGuileWorkerSessionTests",
  "RLMGuileSandboxDenialTests",
  "RLMGuileProcessSignalsTests",
  "RLMGuileOperationTests",
  "RLMChibiWorkerSessionTests",
  "RLMChibiSandboxDenialTests",
  "RLMChibiProcessSignalsTests",
  "RLMChibiOperationTests",
  "RLMWorkerWireParityTests",
];

// Only skip the macOS gate is allowed to report: the descriptor inventory
// needs /proc. It is the evidence for the file-descriptor bounded gap below.
const expectedSkips = new Set([
  "GnosticRLMChibiTests.RLMChibiWorkerSessionTests/fileDescriptorsAbsent()",
]);

const testResults = new Map();
const suites = suiteFilters.map((filter) => {
  const logPath = path.join(evidenceDirectory, `${filter}.log`);
  const xunitPath = path.join(evidenceDirectory, `${filter}-swift-testing.xml`);
  const xunit = fs.readFileSync(xunitPath, "utf8");
  const counts = { passed: 0, skipped: 0, failed: 0 };
  const testCase = /<testcase classname="([^"]+)" name="([^"]+)"[^>]*?(\/>|>([\s\S]*?)<\/testcase>)/g;
  for (const [, className, name, , body = ""] of xunit.matchAll(testCase)) {
    const id = `${className}/${name}`;
    const result = /<failure|<error/.test(body) ? "failed" : /<skipped/.test(body) ? "skipped" : "passed";
    if (result === "failed") throw new Error(`${id} failed on macOS`);
    if (result === "skipped" && !expectedSkips.has(id)) throw new Error(`${id} was skipped unexpectedly`);
    testResults.set(id, result);
    counts[result] += 1;
  }
  const tests = counts.passed + counts.skipped + counts.failed;
  if (tests === 0) throw new Error(`${filter} executed no tests`);
  return {
    filter,
    tests,
    ...counts,
    logSHA256: fileSHA256(logPath),
    xunitSHA256: sha256(Buffer.from(xunit)),
  };
});
for (const skip of expectedSkips) {
  if (testResults.get(skip) !== "skipped") {
    throw new Error(`${skip} was expected to be skipped on macOS; update the file-descriptor row`);
  }
}

const probes = fs.readFileSync(probesPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
for (const probe of probes) {
  if (probe.status !== "passed") throw new Error(`probe ${probe.probe} failed: ${probe.detail}`);
}
const probeNames = new Set(probes.map(({ probe }) => probe));

const guile = (suite, test) => `GnosticRLMGuileTests.${suite}/${test}()`;
const chibi = (suite, test) => `GnosticRLMChibiTests.${suite}/${test}()`;
const parity = (test) => `GnosticRLMWorkerParityTests.RLMWorkerWireParityTests/${test}()`;

// Linux guarantees are the #353 containment matrix in
// Experiments/ChibiRLMWorker/README.md. M13 is satisfied when each is proven on
// macOS or recorded as a bounded gap (manifest §4).
const containment = [
  {
    property: "cpu",
    linuxGuarantee: "Host RLIMIT_CPU applied by gnostic-rlm-limit-exec and verified before exec.",
    macOS: "proven",
    tests: [
      guile("RLMGuileOperationTests", "processLimitsAreInLaunchSpec"),
      guile("RLMGuileWorkerSessionTests", "processLimitsInstalled"),
      chibi("RLMChibiWorkerSessionTests", "processLimitsInstalled"),
      chibi("RLMChibiWorkerSessionTests", "cpuLimitIsEnforced"),
    ],
    probes: ["cpu-limit-applied", "cpu-limit-enforced"],
  },
  {
    property: "address-space",
    linuxGuarantee: "Host RLIMIT_AS applied by gnostic-rlm-limit-exec and verified before exec.",
    macOS: "bounded-gap",
    bound:
      "Darwin has no enforceable RLIMIT_AS, and the launcher refuses the request instead of starting an unbounded worker. Both workers report the address-space limit as absent (-1). Allocation inside the interpreter is still bounded: Chibi by its limited-malloc heap cap, Guile by its per-cell allocation limit. Both keep the worker alive for the next cell. The parent wall deadline and output limit also hold. Only native allocation outside those interpreter caps has no host bound on macOS.",
    tests: [
      guile("RLMGuileWorkerSessionTests", "processLimitsInstalled"),
      guile("RLMGuileWorkerSessionTests", "memoryLimit"),
      guile("RLMGuileWorkerSessionTests", "outputLimit"),
      chibi("RLMChibiWorkerSessionTests", "processLimitsInstalled"),
      chibi("RLMChibiWorkerSessionTests", "memoryLimit"),
      chibi("RLMChibiWorkerSessionTests", "outputLimit"),
    ],
    probes: ["address-space-request-rejected"],
  },
  {
    property: "wall-time",
    linuxGuarantee: "The shared parent session deadline terminates the worker.",
    macOS: "proven",
    tests: [
      guile("RLMGuileWorkerSessionTests", "wallDeadline"),
      guile("RLMGuileWorkerSessionTests", "infiniteEvaluationIsBounded"),
      chibi("RLMChibiWorkerSessionTests", "infiniteEvaluationIsBounded"),
      chibi("RLMChibiWorkerSessionTests", "perCellTimeoutIsRecoverable"),
      parity("containmentStressRecoversBothWorkers"),
    ],
    probes: [],
  },
  {
    property: "file-descriptors",
    linuxGuarantee:
      "Worker tests inspect the Linux child's descriptor inventory through /proc; there is no separate RLIMIT_NOFILE.",
    macOS: "bounded-gap",
    bound:
      "The macOS gate cannot inspect the child's descriptor inventory without /proc. The Chibi inventory test is skipped, and the Guile worker reports no count (-1). The M11 denial suites still hold on macOS: cells cannot reach file, port, or process primitives. So an inherited descriptor cannot be named or used from a cell. The residual gap is that nobody has checked whether one is inherited.",
    tests: [
      chibi("RLMChibiWorkerSessionTests", "fileDescriptorsAbsent"),
      guile("RLMGuileWorkerSessionTests", "credentialsAbsent"),
      guile("RLMGuileSandboxDenialTests", "rejectsDangerousForms"),
      chibi("RLMChibiSandboxDenialTests", "rejectsDangerousForms"),
    ],
    probes: [],
  },
  {
    property: "environment",
    linuxGuarantee: "The executor supplies a scrubbed environment and the worker reports its launch keys.",
    macOS: "proven",
    tests: [
      guile("RLMGuileWorkerSessionTests", "credentialsAbsent"),
      guile("RLMGuileWorkerConfigurationTests", "scrubbedEnvironment"),
      chibi("RLMChibiWorkerSessionTests", "credentialsAbsent"),
      chibi("RLMChibiWorkerConfigurationTests", "scrubbedEnvironment"),
      chibi("RLMChibiOperationTests", "environmentKeysAreInLaunchSpec"),
      parity("readyFrameSanitizesEnvironment"),
    ],
    probes: [],
  },
].map(({ tests, probes: rowProbes, ...row }) => {
  if (row.macOS === "bounded-gap" && !row.bound) throw new Error(`${row.property} gap has no bound`);
  for (const probe of rowProbes) {
    if (!probeNames.has(probe)) throw new Error(`${row.property} cites missing probe ${probe}`);
  }
  return {
    ...row,
    evidence: {
      tests: tests.map((test) => {
        const result = testResults.get(test);
        if (!result) throw new Error(`${row.property} cites ${test}, which did not run`);
        return { test, result };
      }),
      probes: rowProbes,
    },
  };
});

// M14 inputs, restricted to §5a's structural properties at this commit.
// Defect counts and discovery history are deliberately absent.
const chibiBuildScript = fs.readFileSync("Scripts/build-chibi-rlm.sh", "utf8");
const guardBlock = chibiBuildScript.match(/for guard in \\\n([\s\S]*?); do/);
if (!guardBlock) throw new Error("cannot find the Chibi flag guard list");
const chibiFlags = [...guardBlock[1].matchAll(/'SEXP_([A-Z0-9_]+) ([^']+)'/g)].map(
  ([, name, value]) => `SEXP_${name}=${value}`,
);
if (/SEXP_USE_DL=0/.test(chibiBuildScript)) chibiFlags.push("SEXP_USE_DL=0");
const archiveSHA256 = chibiBuildScript.match(/CHIBI_SHA256:-([0-9a-f]{64})/)?.[1];
const chibiVersion = chibiBuildScript.match(/CHIBI_VERSION:-([0-9.]+)/)?.[1];
const patchPath = ".devcontainer/patches/chibi-cell-timeout.patch";
const patch = fs.readFileSync(patchPath, "utf8");
const byteStringTest = chibi("RLMChibiWorkerSessionTests", "stringsAreByteStrings");
const stage0 = JSON.parse(fs.readFileSync("Documentation/Experiments/rlm-scenario-stage0.json", "utf8"));
const linuxGuile = stage0.executorBuilds.find(({ name }) => name === "guile");
const macGuileVersion = environment("GNOSTIC_STAGE1_GUILE_VERSION");

const packaging = {
  status: "recorded",
  scoring:
    "Structural facts per manifest §5a, as of this commit. The comparison scores them at the §6 freeze date; this stage assigns no score.",
  executors: [
    {
      name: "chibi",
      version: chibiVersion,
      source: "pinned upstream archive, built from source by Scripts/build-chibi-rlm.sh on Linux (dev image) and macOS",
      archiveSHA256,
      macOSBinarySHA256: fileSHA256(environment("GNOSTIC_STAGE1_CHIBI")),
      buildFlags: chibiFlags,
      buildFlagCount: chibiFlags.length,
      nonDefaultPatches: [
        {
          path: patchPath,
          sha256: sha256(Buffer.from(patch)),
          files: [...patch.matchAll(/^\+\+\+ b\/(\S+)/gm)].map(([, file]) => file),
          lines: patch.split("\n").length - 1,
        },
      ],
      reproducibility:
        "The build script checks the archive SHA-256 and the patched VM guards before compiling. The Linux image and macOS run the same script.",
      pinning:
        "Exact upstream tag and archive hash. An interpreter upgrade has to re-apply the cell-timeout patch to vm.c and main.c and pass the guard checks again.",
      distribution: "Built and installed by Gnostic's own scripts; no system package.",
      buildConfigurationCoupling: {
        coupled: true,
        property:
          "Frame I/O addresses bytes through character ports, so worker wire correctness depends on SEXP_USE_UTF8_STRINGS staying unset.",
        guard:
          "worker.scm refuses to start when strings are not byte strings, so a flag change fails loudly at startup instead of corrupting frames.",
        pinnedBy: { test: byteStringTest, result: testResults.get(byteStringTest) },
      },
    },
    {
      name: "guile",
      macOSVersion: macGuileVersion,
      macOSFormula: environment("GNOSTIC_STAGE1_GUILE_FORMULA"),
      macOSBinarySHA256: fileSHA256(fs.realpathSync(environment("GNOSTIC_STAGE1_GUILE"))),
      linuxVersion: linuxGuile?.version ?? null,
      source: "system dependency: Homebrew `guile` on macOS, the distribution `guile-3.0` package in the dev image",
      buildFlags: [],
      buildFlagCount: 0,
      nonDefaultPatches: [],
      reproducibility:
        "Not built by Gnostic. The macOS smoke accepts any Guile 3.0.x. The two platforms run different patch releases, which the versions above record.",
      pinning: "Floating within 3.0.x on both platforms; there is no exact version or binary hash pin.",
      distribution:
        "Not bundled or redistributed. The LGPL runtime stays outside Gnostic's distributed artifacts.",
      buildConfigurationCoupling: {
        coupled: false,
        property: "The worker uses a stock distribution build and relies on no build flag.",
      },
    },
  ],
  launcher: {
    source: "Scripts/gnostic-rlm-limit-exec.c",
    sourceSHA256: fileSHA256("Scripts/gnostic-rlm-limit-exec.c"),
    macOSBinarySHA256: fileSHA256(environment("GNOSTIC_STAGE1_LAUNCHER")),
    build: "Scripts/install-rlm-limit-exec.sh compiles one C file with the host compiler on both platforms.",
  },
  platformCoverage: {
    linux: "Stage 0 artifact (dev image): both executors, M1–M6, M11, M12.",
    macOS: `${suites.length} suites / ${suites.reduce((total, { tests }) => total + tests, 0)} tests across both executors and the shared parity suite on this host.`,
  },
};

const artifact = {
  schemaVersion: 1,
  manifestID: "rlm-scenario-manifest-v1",
  manifestVersion: "v6",
  stage: "stage-1-environment",
  outcome: "stage-1-no-spend-complete",
  generatedAtUTC: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  gitCommit: environment("GNOSTIC_STAGE1_COMMIT"),
  providerSpend: "none",
  host: {
    operatingSystem: "darwin",
    operatingSystemVersion: environment("GNOSTIC_STAGE1_OS_VERSION"),
    architecture: environment("GNOSTIC_STAGE1_ARCH"),
    swift: environment("GNOSTIC_STAGE1_SWIFT"),
  },
  suites,
  probes,
  M13: {
    status: containment.every(({ macOS }) => macOS === "proven" || macOS === "bounded-gap") ? "satisfied" : "unavailable",
    rule: "Manifest §4: every Linux guarantee is proven on macOS or recorded as a bounded gap.",
    properties: containment,
  },
  M14: packaging,
};

fs.writeFileSync(outputPath, `${JSON.stringify(artifact, null, 2)}\n`);
