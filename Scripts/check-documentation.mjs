#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, chmodSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, relative, resolve } from "node:path";

// The released package version. A release bumps this constant, the CLI
// version string, and adds the matching compatibility declaration.
const PACKAGE_VERSION = "0.4.2";
const COMPATIBILITY_FILE = `Documentation/Compatibility/${PACKAGE_VERSION}.md`;

const REQUIRED_FILES = [
  "CONTEXT.md",
  "Documentation/Architecture/README.md",
  "Documentation/Architecture/ADRs/0001-axoloty-native-multi-backend-host.md",
  "Documentation/Architecture/ADRs/0002-gnostic-identity-vs-backend-state.md",
  "Documentation/Architecture/ADRs/0003-pre-1-0-manifest-and-protocol-reset.md",
  "Documentation/Architecture/ADRs/0004-atlas-supersedes-narrative.md",
  "Documentation/Architecture/exceptions.json",
  "Documentation/Architecture/experiments.json",
  COMPATIBILITY_FILE,
];

const ADR_FILES = REQUIRED_FILES.filter((file) => file.includes("/ADRs/"));
const EXCEPTION_FIELDS = ["id", "rule", "scope", "rationale", "issue", "owner", "reconsiderWhen"];
const MODULE_FILE = "Documentation/Architecture/experiments.json";
const MODULE_FIELDS = ["id", "name", "targets", "status", "owningIssue", "gateIssues", "runnable", "reviewBy"];
// Lifecycle statuses from ADR 0013. `archived` is terminal: its owning issue is
// expected to be closed, so only the other statuses demand an open owner.
const MODULE_STATUSES = ["incubating", "gated", "promoted", "parked", "archived"];
const ACTIVE_MODULE_STATUSES = MODULE_STATUSES.filter((status) => status !== "archived");
const ISSUE_URL_PATTERN = /^https:\/\/github\.com\/phynics\/Gnostic\/issues\/(\d+)$/;

function parseArguments(argv) {
  const options = { root: process.cwd(), cliPath: null, selfTest: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--self-test") {
      options.selfTest = true;
    } else if (argument === "--root") {
      options.root = resolve(argv[++index]);
    } else if (argument === "--cli") {
      options.cliPath = resolve(argv[++index]);
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  return options;
}

function readText(root, file) {
  return readFileSync(join(root, file), "utf8");
}

function markdownFiles(root) {
  const files = [];
  const ignored = new Set([".git", ".build", ".swiftpm", ".swiftpm-cache", ".testing", "node_modules"]);
  const visit = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (entry.isDirectory() && !ignored.has(entry.name)) {
        visit(join(directory, entry.name));
      } else if (entry.isFile() && extname(entry.name).toLowerCase() === ".md") {
        files.push(relative(root, join(directory, entry.name)));
      }
    }
  };
  visit(root);
  return files;
}

function makeTargets(root) {
  const makefile = readText(root, "Makefile");
  return new Set([...makefile.matchAll(/^([A-Za-z0-9_.-]+):/gm)].map((match) => match[1]));
}

function documentedMakeTargets(text) {
  return [...text.matchAll(/(?:^|`)\s*make\s+([A-Za-z0-9_.-]+)/gm)].map((match) => match[1]);
}

function shellTokens(line) {
  const tokens = [];
  const pattern = /"([^"\\]*(?:\\.[^"\\]*)*)"|'([^']*)'|([^\s]+)/g;
  for (const match of line.matchAll(pattern)) {
    tokens.push(match[1] ?? match[2] ?? match[3]);
  }
  return tokens;
}

function documentedCLIChains(readme) {
  const chains = [];
  for (const line of readme.split("\n")) {
    const match = line.match(/^\s*(?:[$]\s*)?gnostic(?:\s+(.*))?$/);
    if (!match) continue;
    const chain = [];
    for (const token of shellTokens(match[1] ?? "")) {
      if (token.startsWith("-")) break;
      if (token === "\\") break;
      chain.push(token);
    }
    chains.push(chain);
  }
  return chains;
}

function sourceText(root) {
  return sourceFiles(root, "Sources").map(({ text }) => text).join("\n");
}

function sourceFiles(root, directory) {
  const files = [];
  const visit = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile() && /\.(swift|m|mm|h|c|cpp|cc|js|mjs|ts)$/.test(entry.name)) {
        files.push({ path, text: readFileSync(path, "utf8") });
      }
    }
  };
  const sources = join(root, directory);
  try {
    visit(sources);
  } catch {
    return [];
  }
  return files;
}

function validateMarkdownLinks(root, failures) {
  for (const file of markdownFiles(root)) {
    const text = readText(root, file);
    for (const match of text.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
      const target = match[1].trim().replace(/^<|>$/g, "");
      if (!target || /^(?:[a-z][a-z0-9+.-]*:|#)/i.test(target)) continue;
      const pathTarget = target.split("#", 1)[0].split("?", 1)[0];
      if (!pathTarget) continue;
      const resolved = resolve(dirname(join(root, file)), pathTarget);
      try {
        readFileSync(resolved);
      } catch {
        failures.push(`${file}: broken local Markdown link '${target}'`);
      }
    }
  }
}

function validateADRs(root, failures) {
  for (const file of ADR_FILES) {
    const text = readText(root, file).toLowerCase();
    for (const section of ["status", "context", "decision", "rejected alternatives", "consequences", "reconsideration triggers"]) {
      if (!new RegExp(`^#+\\s*${section.replace(/[.*+?^${}()|[\\]\\]/g, "\\$&")}`, "m").test(text)) {
        failures.push(`${file}: missing ADR section '${section}'`);
      }
    }
    if (!text.includes("github.com/phynics/gnostic/issues/140") || !text.includes("github.com/phynics/gnostic/issues/145")) {
      failures.push(`${file}: must link to issues #140 and #145`);
    }
  }
}

function validateExceptions(root, failures) {
  const file = "Documentation/Architecture/exceptions.json";
  let document;
  try {
    document = JSON.parse(readText(root, file));
  } catch (error) {
    failures.push(`${file}: invalid JSON (${error.message})`);
    return;
  }
  if (document.schemaVersion !== 1) failures.push(`${file}: schemaVersion must be 1`);
  if (!Array.isArray(document.exceptions)) {
    failures.push(`${file}: exceptions must be an array`);
    return;
  }
  const ids = new Set();
  document.exceptions.forEach((entry, index) => {
    const prefix = `${file}: exceptions[${index}]`;
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      failures.push(`${prefix} must be an object`);
      return;
    }
    for (const field of EXCEPTION_FIELDS) {
      if (typeof entry[field] !== "string" || entry[field].trim() === "") failures.push(`${prefix}.${field} must be a non-empty string`);
    }
    if (ids.has(entry.id)) failures.push(`${prefix}.id '${entry.id}' is not unique`);
    ids.add(entry.id);
    const scopes = Array.isArray(entry.scope) ? entry.scope : [entry.scope];
    if (scopes.some((scope) => typeof scope === "string" && /\*/.test(scope))) failures.push(`${prefix}.scope may not use wildcard targets`);
  });
}

// Every `.target(...)` and `.executableTarget(...)` name declared in
// Package.swift. A registry entry may only name targets that exist there.
function packageTargetNames(packageText) {
  const names = new Set();
  const pattern = /\.(?:target|executableTarget|testTarget)\(\s*name:\s*"([^"]+)"/g;
  for (const match of packageText.matchAll(pattern)) names.add(match[1]);
  return names;
}

// `reviewBy` is a UTC calendar date. Reject anything Date cannot parse as an
// exact ISO day so a typo cannot silently defer a review forever.
function isISODate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

// Validate the module registry against ADR 0013. `issueState` is an optional
// async resolver `(issueUrl) => "open" | "closed" | "unknown"`. Callers that can
// reach GitHub pass one so an active entry owned by a closed issue is rejected;
// without it the issue-state rule is skipped, not silently passed.
async function validateExperiments(root, failures, { issueState = null } = {}) {
  let document;
  try {
    document = JSON.parse(readText(root, MODULE_FILE));
  } catch (error) {
    failures.push(`${MODULE_FILE}: invalid JSON (${error.message})`);
    return;
  }
  if (document.schemaVersion !== 1) failures.push(`${MODULE_FILE}: schemaVersion must be 1`);
  if (!Array.isArray(document.modules)) {
    failures.push(`${MODULE_FILE}: modules must be an array`);
    return;
  }
  const targets = packageTargetNames(readText(root, "Package.swift"));
  const ids = new Set();
  const stateByUrl = new Map();
  for (const [index, entry] of document.modules.entries()) {
    const prefix = `${MODULE_FILE}: modules[${index}]`;
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      failures.push(`${prefix} must be an object`);
      continue;
    }
    for (const field of MODULE_FIELDS) {
      if (!(field in entry)) failures.push(`${prefix}.${field} is required`);
    }
    for (const field of ["id", "name", "status", "owningIssue"]) {
      if (typeof entry[field] !== "string" || entry[field].trim() === "") failures.push(`${prefix}.${field} must be a non-empty string`);
    }
    if (typeof entry.id === "string" && entry.id.trim() !== "") {
      if (ids.has(entry.id)) failures.push(`${prefix}.id '${entry.id}' is not unique`);
      ids.add(entry.id);
    }
    if (typeof entry.status === "string" && !MODULE_STATUSES.includes(entry.status)) {
      failures.push(`${prefix}.status '${entry.status}' must be one of ${MODULE_STATUSES.join(", ")}`);
    }
    if (typeof entry.runnable !== "boolean") failures.push(`${prefix}.runnable must be a boolean`);
    if (!isISODate(entry.reviewBy)) failures.push(`${prefix}.reviewBy must be an ISO date (YYYY-MM-DD)`);
    if (!Array.isArray(entry.targets)) {
      failures.push(`${prefix}.targets must be an array`);
    } else {
      for (const target of entry.targets) {
        if (typeof target !== "string" || target.trim() === "") failures.push(`${prefix}.targets entries must be non-empty strings`);
        else if (!targets.has(target)) failures.push(`${prefix}.targets names unknown Package.swift target '${target}'`);
      }
    }
    if (entry.owningIssue && typeof entry.owningIssue === "string" && !ISSUE_URL_PATTERN.test(entry.owningIssue)) {
      failures.push(`${prefix}.owningIssue must be a phynics/Gnostic issue URL`);
    }
    if (!Array.isArray(entry.gateIssues)) {
      failures.push(`${prefix}.gateIssues must be an array`);
    } else if (entry.gateIssues.length === 0) {
      failures.push(`${prefix}.gateIssues must name at least one gate issue`);
    } else {
      const gates = new Set();
      for (const gate of entry.gateIssues) {
        if (typeof gate !== "string" || gate.trim() === "") failures.push(`${prefix}.gateIssues entries must be non-empty strings`);
        else if (!ISSUE_URL_PATTERN.test(gate)) failures.push(`${prefix}.gateIssues entry '${gate}' must be a phynics/Gnostic issue URL`);
        else if (gates.has(gate)) failures.push(`${prefix}.gateIssues entry '${gate}' is duplicated`);
        else gates.add(gate);
      }
    }
    if (issueState && ACTIVE_MODULE_STATUSES.includes(entry.status) && ISSUE_URL_PATTERN.test(entry.owningIssue ?? "")) {
      let state = stateByUrl.get(entry.owningIssue);
      if (state === undefined) {
        state = await issueState(entry.owningIssue);
        stateByUrl.set(entry.owningIssue, state);
      }
      if (state === "closed") failures.push(`${prefix}.owningIssue is closed but status '${entry.status}' is active`);
      // "unknown" means the resolver could not reach GitHub. Skip it rather
      // than fail the whole check on a transient network or auth problem; the
      // self-test pins the closed-owner contract.
    }
  }

  // A compiled-in descriptor names the registry entry it implements, so a
  // module cannot ship without a registry record (ADR 0013).
  const compiledRegistryIDs = new Set();
  for (const { text } of sourceFiles(root, "Sources/GnosticHost")) {
    for (const match of text.matchAll(/registryID:\s*"([^"]+)"/g)) compiledRegistryIDs.add(match[1]);
  }
  for (const id of compiledRegistryIDs) {
    if (!ids.has(id)) {
      failures.push(`Sources/GnosticHost: compiled-in module registryID '${id}' has no entry in ${MODULE_FILE}`);
    }
  }

  // A `runnable` entry must have a descriptor, so a module cannot advertise
  // manifest runnability that nothing can build.
  for (const entry of document.modules) {
    if (typeof entry.id !== "string" || !entry.runnable) continue;
    if (!compiledRegistryIDs.has(entry.id)) {
      failures.push(`${MODULE_FILE}: runnable entry '${entry.id}' has no compiled module descriptor in Sources/GnosticHost`);
    }
  }
}

function swiftTargetBlock(packageText, name) {
  const targetStart = packageText.search(new RegExp(`\\.target\\(\\s*name:\\s*"${name}"`));
  const targetEndMarker = "\n        ),";
  const targetEnd = targetStart < 0 ? -1 : packageText.indexOf(targetEndMarker, targetStart);
  if (targetStart < 0 || targetEnd < 0) return null;
  return packageText.slice(targetStart, targetEnd + targetEndMarker.length);
}

function validateResetBaseline(root, failures) {
  const packageText = readText(root, "Package.swift");
  if (!packageText.includes('.library(name: "GnosticPositronicAtlas", targets: ["GnosticPositronicAtlas"])')) {
    failures.push("Package.swift: Atlas boundary product is missing");
  }
  const coreTarget = swiftTargetBlock(packageText, "GnosticCore");
  if (!coreTarget) {
    failures.push("Package.swift: GnosticCore target is missing");
  } else if (coreTarget.includes("GnosticPositronicAtlas")) {
    failures.push("Package.swift: GnosticCore must not depend on GnosticPositronicAtlas");
  }
  const atlasTarget = swiftTargetBlock(packageText, "GnosticPositronicAtlas");
  if (!atlasTarget) {
    failures.push("Package.swift: GnosticPositronicAtlas target is missing");
  } else {
    if (!atlasTarget.includes('"GnosticCore"')) failures.push("Package.swift: Atlas target must depend on GnosticCore");
    if (!atlasTarget.includes("PositronicKit")) failures.push("Package.swift: Atlas target must depend on PositronicKit");
  }

  for (const { path, text } of sourceFiles(root, "Sources/GnosticCore")) {
    if (/Narrative/.test(text)) failures.push(`${relative(root, path)}: Narrative must not remain in GnosticCore`);
    if (/import\s+GnosticPositronicAtlas\b/.test(text)) failures.push(`${relative(root, path)}: GnosticCore must not import Atlas`);
  }

  const compatibility = readText(root, COMPATIBILITY_FILE).toLowerCase();
  for (const phrase of [PACKAGE_VERSION, "protocol major", "manifest v2", "v1", "migration", "bundled", "atlas", "narrative", "0.2"]) {
    if (!compatibility.includes(phrase)) failures.push(`${COMPATIBILITY_FILE}: compatibility declaration must mention '${phrase}'`);
  }
}

function validateVolatileText(root, failures) {
  for (const file of ["AGENTS.md", "README.md"]) {
    const text = readText(root, file);
    if (/^##+\s+(?:current\s+)?baseline\b/im.test(text) || /^##+\s+(?:current|repository)\s+(?:status|state|environment|versions?)\b/im.test(text) || /^##+\s+volatile\b/im.test(text)) {
      failures.push(`${file}: volatile baseline/status section is not allowed`);
    }
    if (/\b\d+\s+(?:swift\s+testing\s+)?tests?\b/i.test(text) || /\b\d+\s+suites?\b/i.test(text)) {
      failures.push(`${file}: exact test/suite counts are not allowed`);
    }
    if (/(?:revision|commit|sha|pinned|pinned\s+to|temporary)\b[^\n]{0,100}\b[0-9a-f]{7,40}\b/i.test(text)) {
      failures.push(`${file}: temporary dependency revisions are not allowed`);
    }
  }
}

function validateCLI(root, cliPath, failures, cliArgs = [], cliRunner = null) {
  if (!cliPath) {
    failures.push("README.md: CLI help checks require --cli pointing to the built gnostic executable");
    return;
  }
  const runHelp = (chain) => cliRunner
    ? cliRunner({ cliPath, cliArgs, chain })
    : spawnSync(cliPath, [...cliArgs, ...chain, "--help"], { encoding: "utf8" });
  const compatibility = readText(root, COMPATIBILITY_FILE);
  const declaredVersion = compatibility.match(/^[-*]\s*Package version:\s*`([^`]+)`\./m)?.[1];
  if (!declaredVersion) {
    failures.push(`${COMPATIBILITY_FILE}: package version is missing`);
  } else {
    const versionResult = cliRunner
      ? cliRunner({ cliPath, cliArgs, chain: [], action: "version" })
      : spawnSync(cliPath, [...cliArgs, "--version"], { encoding: "utf8" });
    const actualVersion = `${versionResult.stdout ?? ""}`.trim();
    if (versionResult.error || versionResult.status !== 0) {
      const detail = versionResult.error?.message ?? (versionResult.stderr || actualVersion || `exit ${versionResult.status}`).trim();
      failures.push(`gnostic --version failed (${detail})`);
    } else if (actualVersion !== declaredVersion) {
      failures.push(`gnostic --version '${actualVersion}' does not match declared package version '${declaredVersion}'`);
    }
  }
  const rootHelp = runHelp([]);
  if (rootHelp.error || rootHelp.status !== 0) {
    const detail = rootHelp.error?.message ?? (rootHelp.stderr || rootHelp.stdout || `exit ${rootHelp.status}`).trim();
    failures.push(`gnostic --help failed (${detail})`);
  } else {
    const output = `${rootHelp.stdout ?? ""}\n${rootHelp.stderr ?? ""}`;
    if (!/(?:^|\n)\s*acp(?:\s|$)/i.test(output)) failures.push("gnostic --help must advertise 'acp' as the interaction layer");
    if (/(?:^|\n)\s*turn(?:\s|$)/i.test(output)) failures.push("gnostic --help must not advertise removed 'turn' command");
  }
  const removedTurn = cliRunner
    ? cliRunner({ cliPath, cliArgs, chain: ["turn"] })
    : spawnSync(cliPath, [...cliArgs, "turn"], { encoding: "utf8" });
  if (!removedTurn.error && removedTurn.status === 0) {
    failures.push("gnostic turn must fail because the direct Turn CLI is removed");
  }
  for (const chain of documentedCLIChains(readText(root, "README.md"))) {
    const result = runHelp(chain);
    if (result.error || result.status !== 0) {
      const command = ["gnostic", ...chain].join(" ");
      const detail = result.error?.message ?? (result.stderr || result.stdout || `exit ${result.status}`).trim();
      failures.push(`README.md: documented CLI command '${command}' failed --help (${detail})`);
    }
  }
}

export async function checkRepository({ root = process.cwd(), cliPath = null, cliArgs = [], cliRunner = null, issueState = null } = {}) {
  const failures = [];
  for (const file of REQUIRED_FILES) {
    try {
      readFileSync(join(root, file));
    } catch {
      failures.push(`${file}: required documentation file is missing`);
    }
  }
  try {
    const makeTargets = makeTargetsForRoot(root);
    for (const file of markdownFiles(root)) {
      for (const target of documentedMakeTargets(readText(root, file))) {
        if (!makeTargets.has(target)) failures.push(`${file}: documented Make target 'make ${target}' does not exist`);
      }
    }
  } catch (error) {
    failures.push(`Makefile: cannot inspect documented targets (${error.message})`);
  }
  try {
    validateMarkdownLinks(root, failures);
  } catch (error) {
    failures.push(`Markdown links: ${error.message}`);
  }
  try {
    validateVolatileText(root, failures);
  } catch (error) {
    failures.push(`AGENTS.md/README.md: cannot inspect documents (${error.message})`);
  }
  try {
    if (/\.package\s*\(\s*path\s*:/.test(readText(root, "Package.swift"))) failures.push("Package.swift: committed local-path dependencies are not allowed");
  } catch (error) {
    failures.push(`Package.swift: cannot inspect dependencies (${error.message})`);
  }
  try {
    validateExceptions(root, failures);
  } catch (error) {
    failures.push(`Documentation/Architecture/exceptions.json: ${error.message}`);
  }
  try {
    await validateExperiments(root, failures, { issueState });
  } catch (error) {
    failures.push(`${MODULE_FILE}: ${error.message}`);
  }
  try {
    validateResetBaseline(root, failures);
  } catch (error) {
    failures.push(`RESET-006 baseline: ${error.message}`);
  }
  try {
    validateADRs(root, failures);
  } catch (error) {
    failures.push(`Documentation/Architecture/ADRs: ${error.message}`);
  }
  try {
    const readme = readText(root, "README.md");
    const source = sourceText(root);
    for (const phrase of ["list_network_objects", "inspect_network_object", "gnostic chat", "gnostic turn"]) {
      if (readme.includes(phrase)) failures.push(`README.md: removed command or operation '${phrase}' is still documented`);
    }
    for (const identifier of new Set([...readme.matchAll(/\bme\.atkn\.gnostic\.[A-Za-z0-9_.-]+/g)].map((match) => match[0]))) {
      if (!source.includes(identifier)) failures.push(`README.md: protocol identifier '${identifier}' does not occur in Sources`);
    }
    validateCLI(root, cliPath, failures, cliArgs, cliRunner);
  } catch (error) {
    failures.push(`README.md: cannot inspect identifiers or CLI examples (${error.message})`);
  }
  if (failures.length > 0) {
    const error = new Error(`Documentation checks failed:\n- ${failures.join("\n- ")}`);
    error.failures = failures;
    throw error;
  }
  return { checked: REQUIRED_FILES.length, failures: [] };
}

function makeTargetsForRoot(root) {
  return makeTargets(root);
}

function writeDescriptorFixture(root, registryID) {
  const path = join(root, "Sources/GnosticHost/RLMModule.swift");
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `let value = GnosticModule(
    name: "rlm",
    registryID: "${registryID}",
    settingKeys: [],
    terminalTurnObservers: []
) { _ in NotesContribution() }
`);
}

function writeFixture(root) {
  rmSync(join(root, "Sources"), { recursive: true, force: true });
  const files = {
    "AGENTS.md": "# Agent Instructions\n\nUse CONTEXT.md and the architecture index.\n",
    "README.md": "# Fixture\n\nRun `make docs-check`. Protocol: `me.atkn.gnostic.workspace.invoke`.\n\n```sh\ngnostic acp profiles --json\n```\n",
    "CONTEXT.md": "# Context\n",
    "Makefile": "docs-check:\nverify:\n",
    "Package.swift": `let package = Package(
    products: [
        .library(name: "GnosticPositronicAtlas", targets: ["GnosticPositronicAtlas"]),
    ],
    targets: [
        .target(
            name: "GnosticCore"
        ),
        .target(
            name: "GnosticPositronicAtlas",
            dependencies: [
                "GnosticCore",
                .product(name: "PositronicKit", package: "PositronicKit"),
            ]
        ),
    ]
)
`,
    [COMPATIBILITY_FILE]: `# Compatibility\n\n- Package version: \`${PACKAGE_VERSION}\`.\n\nPackage ${PACKAGE_VERSION} uses protocol major 2 and manifest v2; v1 migration is supported. Bundled Atlas status is scaffold-only, and Narrative is superseded after the intentional 0.2 break.\n`,
    "Sources/GnosticCore/Core.swift": "let core = true\n",
    "Sources/Protocol.swift": "let route = \"me.atkn.gnostic.workspace.invoke\"\n",
    "Documentation/Architecture/README.md": "# Architecture\n\n[ADR 0001](ADRs/0001-axoloty-native-multi-backend-host.md) [ADR 0002](ADRs/0002-gnostic-identity-vs-backend-state.md) [ADR 0003](ADRs/0003-pre-1-0-manifest-and-protocol-reset.md) [ADR 0004](ADRs/0004-atlas-supersedes-narrative.md)\n",
    "Documentation/Architecture/exceptions.json": JSON.stringify({ schemaVersion: 1, exceptions: [] }, null, 2),
    "Documentation/Architecture/experiments.json": JSON.stringify({
      schemaVersion: 1,
      modules: [{
        id: "GNO-MOD-ATLAS",
        name: "Atlas continuity and context",
        targets: ["GnosticPositronicAtlas"],
        status: "incubating",
        owningIssue: "https://github.com/phynics/Gnostic/issues/449",
        gateIssues: ["https://github.com/phynics/Gnostic/issues/382"],
        runnable: false,
        reviewBy: "2027-01-02",
      }],
    }, null, 2),
  };
  const adrNames = {
    "0001": "0001-axoloty-native-multi-backend-host.md",
    "0002": "0002-gnostic-identity-vs-backend-state.md",
    "0003": "0003-pre-1-0-manifest-and-protocol-reset.md",
    "0004": "0004-atlas-supersedes-narrative.md",
  };
  for (const number of Object.keys(adrNames)) {
    files[`Documentation/Architecture/ADRs/${adrNames[number]}`] = [
      "# ADR",
      "## Status",
      "Accepted",
      "## Context",
      "Fixture context",
      "## Decision",
      "Fixture decision",
      "## Rejected alternatives",
      "None",
      "## Consequences",
      "Fixture consequences",
      "## Reconsideration triggers",
      "Fixture trigger",
      "[Epic #140](https://github.com/phynics/Gnostic/issues/140) [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)",
    ].join("\n");
  }
  for (const [file, content] of Object.entries(files)) {
    const path = join(root, file);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content);
  }
  const cli = join(root, "fake-gnostic");
  writeFileSync(cli, "#!/usr/bin/env node\nif (process.argv.includes('does-not-exist')) process.exit(1);\nprocess.exit(0);\n");
  chmodSync(cli, 0o755);
  return cli;
}

function expectFailure(root, options, mutate, expected) {
  mutate();
  return assert.rejects(() => checkRepository({ root, ...options }), (error) => error.message.includes(expected));
}

async function selfTest() {
  const root = mkdtempSync(join(tmpdir(), "gnostic-documentation-check-"));
  try {
    writeFixture(root);
    const options = {
      cliPath: "fixture-gnostic",
      issueState: async () => "open",
      cliRunner: ({ chain, action }) => {
        if (action === "version") return { status: 0, stdout: `${PACKAGE_VERSION}\n` };
        if (chain.length === 0) return { status: 0, stdout: "SUBCOMMANDS:\n  acp  Run ACP\n" };
        if (chain.includes("turn") || chain.includes("does-not-exist")) return { status: 1, stderr: "unknown command" };
        return { status: 0, stdout: "help" };
      },
    };
    assert.deepEqual(await checkRepository({ root, ...options }), { checked: REQUIRED_FILES.length, failures: [] });
    writeFixture(root);
    await expectFailure(
      root,
      { ...options, cliRunner: ({ chain, action }) => action === "version"
        ? { status: 0, stdout: "0.2.0\n" }
        : options.cliRunner({ chain, action }) },
      () => {},
      "does not match declared package version"
    );
    await expectFailure(root, options, () => writeFileSync(join(root, COMPATIBILITY_FILE), "# Compatibility\n"), `must mention '${PACKAGE_VERSION}'`);
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(join(root, "Package.swift"), readText(root, "Package.swift").replace('                "GnosticCore",\n', "")), "Atlas target must depend on GnosticCore");
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(join(root, "Documentation/Architecture/README.md"), "[broken](missing.md)"), "broken local Markdown link");
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(join(root, "README.md"), "make nonexistent-target\n"), "nonexistent-target");
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(join(root, "AGENTS.md"), "## Current baseline\n"), "volatile baseline/status");
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(join(root, "AGENTS.md"), "245 tests\n"), "exact test/suite counts");
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(join(root, "Documentation/Architecture/exceptions.json"), JSON.stringify({ schemaVersion: 1, exceptions: [{ id: "x" }] })), "exceptions[0].rule");
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(join(root, "Package.swift"), ".package(path: \"../local\")"), "local-path dependencies");
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(join(root, "README.md"), "gnostic does-not-exist\n"), "documented CLI command 'gnostic does-not-exist'");
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(join(root, "README.md"), "list_network_objects\n"), "removed command or operation 'list_network_objects'");

    // Module registry: malformed entry, unknown target, closed owner, and the
    // status/runnable/date contract each reject independently.
    const registryFile = join(root, "Documentation/Architecture/experiments.json");
    const fixtureRegistry = () => JSON.parse(readText(root, "Documentation/Architecture/experiments.json"));
    writeFixture(root);
    await expectFailure(root, options, () => writeFileSync(registryFile, JSON.stringify({ schemaVersion: 1, modules: [{ id: "X" }] })), "modules[0].name is required");
    writeFixture(root);
    await expectFailure(root, options, () => {
      const document = fixtureRegistry();
      document.modules[0].targets = ["GnosticNonexistent"];
      writeFileSync(registryFile, JSON.stringify(document));
    }, "names unknown Package.swift target 'GnosticNonexistent'");
    writeFixture(root);
    await expectFailure(root, { ...options, issueState: async () => "closed" }, () => {}, "owningIssue is closed but status 'incubating' is active");
    writeFixture(root);
    await expectFailure(root, options, () => {
      const document = fixtureRegistry();
      document.modules[0].status = "bogus";
      writeFileSync(registryFile, JSON.stringify(document));
    }, "must be one of incubating, gated, promoted, parked, archived");
    writeFixture(root);
    await expectFailure(root, options, () => {
      const document = fixtureRegistry();
      document.modules[0].runnable = "yes";
      writeFileSync(registryFile, JSON.stringify(document));
    }, "runnable must be a boolean");
    writeFixture(root);
    await expectFailure(root, options, () => {
      const document = fixtureRegistry();
      document.modules[0].reviewBy = "2027-13-40";
      writeFileSync(registryFile, JSON.stringify(document));
    }, "reviewBy must be an ISO date");
    writeFixture(root);
    await expectFailure(root, options, () => {
      const document = fixtureRegistry();
      document.modules[0].gateIssues = ["https://github.com/phynics/Gnostic/pull/1"];
      writeFileSync(registryFile, JSON.stringify(document));
    }, "must be a phynics/Gnostic issue URL");
    writeFixture(root);
    await expectFailure(root, options, () => {
      const document = fixtureRegistry();
      document.modules[0].gateIssues = [];
      writeFileSync(registryFile, JSON.stringify(document));
    }, "must name at least one gate issue");
    writeFixture(root);
    await expectFailure(root, options, () => {
      const gate = "https://github.com/phynics/Gnostic/issues/382";
      const document = fixtureRegistry();
      document.modules[0].gateIssues = [gate, gate];
      writeFileSync(registryFile, JSON.stringify(document));
    }, "is duplicated");
    writeFixture(root);
    // A `runnable` entry must have a compiled-in descriptor: the registry may
    // not advertise runnability that nothing can build.
    writeDescriptorFixture(root, "GNO-MOD-ATLAS");
    assert.deepEqual(await checkRepository({ root, ...options }), { checked: REQUIRED_FILES.length, failures: [] });
    writeFixture(root);
    await expectFailure(root, options, () => {
      const document = fixtureRegistry();
      document.modules[0].runnable = true;
      writeFileSync(registryFile, JSON.stringify(document));
    }, "runnable entry 'GNO-MOD-ATLAS' has no compiled module descriptor");
    writeFixture(root);
    // A runnable entry whose descriptor names a different registry id is still
    // uncovered: the id must match the entry, not merely exist.
    writeDescriptorFixture(root, "GNO-MOD-MISSING");
    await expectFailure(root, options, () => {
      const document = fixtureRegistry();
      document.modules[0].runnable = true;
      writeFileSync(registryFile, JSON.stringify(document));
    }, "runnable entry 'GNO-MOD-ATLAS' has no compiled module descriptor");

    writeFixture(root);
    // A resolver that cannot reach GitHub must not fail the check; only a
    // confirmed closed owner does.
    assert.deepEqual(await checkRepository({ root, ...options, issueState: async () => "unknown" }), { checked: REQUIRED_FILES.length, failures: [] });
    // An archived entry may be owned by a closed issue, so the active-entry
    // rule must not fire there.
    writeFixture(root);
    {
      const document = fixtureRegistry();
      document.modules[0].status = "archived";
      writeFileSync(registryFile, JSON.stringify(document));
      assert.deepEqual(await checkRepository({ root, ...options, issueState: async () => "closed" }), { checked: REQUIRED_FILES.length, failures: [] });
    }

    writeFixture(root);
    // A compiled-in descriptor must name a real registry entry.
    mkdirSync(join(root, "Sources/GnosticHost"), { recursive: true });
    writeFileSync(
      join(root, "Sources/GnosticHost/Composition.swift"),
      'let module = GnosticModule(name: "rlm", registryID: "GNO-MOD-MISSING")\n'
    );
    await assert.rejects(
      () => checkRepository({ root, ...options }),
      (error) => error.message.includes("registryID 'GNO-MOD-MISSING' has no entry")
    );
    rmSync(join(root, "Sources/GnosticHost"), { recursive: true, force: true });
    writeFixture(root);
    await assert.rejects(
      () => checkRepository({
        root,
        ...options,
        cliRunner: ({ chain }) => chain.length === 0
          ? { status: 0, stdout: "SUBCOMMANDS:\n" }
          : { status: 1, stderr: "unknown command" },
      }),
      (error) => error.message.includes("must advertise 'acp'")
    );
    writeFixture(root);
    await assert.rejects(
      () => checkRepository({
        root,
        ...options,
        cliRunner: ({ chain }) => chain.length === 0
          ? { status: 0, stdout: "SUBCOMMANDS:\n  acp  Run ACP\n  turn  Run Turn\n" }
          : { status: chain.includes("turn") ? 0 : 1 },
      }),
      (error) => error.message.includes("must not advertise removed 'turn'")
    );
    console.log("Documentation checker self-tests passed");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// Resolve the state of a phynics/Gnostic issue through the GitHub REST API.
// Returns "open", "closed", or "unknown" (no token or a failed request).
function githubIssueStateResolver(token) {
  return async (issueUrl) => {
    const number = ISSUE_URL_PATTERN.exec(issueUrl)?.[1];
    if (!number) return "unknown";
    try {
      const response = await fetch(`https://api.github.com/repos/phynics/Gnostic/issues/${number}`, {
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${token}`,
          "User-Agent": "gnostic-docs-check",
        },
      });
      if (!response.ok) return "unknown";
      const state = (await response.json()).state;
      return state === "open" || state === "closed" ? state : "unknown";
    } catch {
      return "unknown";
    }
  };
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfTest) {
    await selfTest();
    return;
  }
  // Enforce the open-owning-issue rule only when GitHub can be reached. The
  // self-test injects a deterministic resolver instead; CI has no token, and
  // an unauthenticated API call would rate-limit.
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN || null;
  const issueState = token ? githubIssueStateResolver(token) : null;
  try {
    await checkRepository({ root: options.root, cliPath: options.cliPath, issueState });
    console.log("Documentation checks passed");
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

await main();
