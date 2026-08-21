#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, chmodSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, relative, resolve } from "node:path";

const REQUIRED_FILES = [
  "CONTEXT.md",
  "Documentation/Architecture/README.md",
  "Documentation/Architecture/ADRs/0001-axoloty-native-multi-backend-host.md",
  "Documentation/Architecture/ADRs/0002-gnostic-identity-vs-backend-state.md",
  "Documentation/Architecture/ADRs/0003-pre-1-0-manifest-and-protocol-reset.md",
  "Documentation/Architecture/ADRs/0004-atlas-supersedes-narrative.md",
  "Documentation/Architecture/exceptions.json",
  "Documentation/Compatibility/0.3.0.md",
];

const ADR_FILES = REQUIRED_FILES.filter((file) => file.includes("/ADRs/"));
const EXCEPTION_FIELDS = ["id", "rule", "scope", "rationale", "issue", "owner", "reconsiderWhen"];

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

  const compatibility = readText(root, "Documentation/Compatibility/0.3.0.md").toLowerCase();
  for (const phrase of ["0.3.0", "protocol major", "manifest v2", "v1", "migration", "bundled", "atlas", "narrative", "0.2"]) {
    if (!compatibility.includes(phrase)) failures.push(`Documentation/Compatibility/0.3.0.md: compatibility declaration must mention '${phrase}'`);
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

export function checkRepository({ root = process.cwd(), cliPath = null, cliArgs = [], cliRunner = null } = {}) {
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

function writeFixture(root) {
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
    "Documentation/Compatibility/0.3.0.md": "# Compatibility\n\nPackage 0.3.0 uses protocol major 2 and manifest v2; v1 migration is supported. Bundled Atlas status is scaffold-only, and Narrative is superseded after the intentional 0.2 break.\n",
    "Sources/GnosticCore/Core.swift": "let core = true\n",
    "Sources/Protocol.swift": "let route = \"me.atkn.gnostic.workspace.invoke\"\n",
    "Documentation/Architecture/README.md": "# Architecture\n\n[ADR 0001](ADRs/0001-axoloty-native-multi-backend-host.md) [ADR 0002](ADRs/0002-gnostic-identity-vs-backend-state.md) [ADR 0003](ADRs/0003-pre-1-0-manifest-and-protocol-reset.md) [ADR 0004](ADRs/0004-atlas-supersedes-narrative.md)\n",
    "Documentation/Architecture/exceptions.json": JSON.stringify({ schemaVersion: 1, exceptions: [] }, null, 2),
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
  assert.throws(() => checkRepository({ root, ...options }), (error) => error.message.includes(expected));
}

function selfTest() {
  const root = mkdtempSync(join(tmpdir(), "gnostic-documentation-check-"));
  try {
    writeFixture(root);
    const options = {
      cliPath: "fixture-gnostic",
      cliRunner: ({ chain }) => {
        if (chain.length === 0) return { status: 0, stdout: "SUBCOMMANDS:\n  acp  Run ACP\n" };
        if (chain.includes("turn") || chain.includes("does-not-exist")) return { status: 1, stderr: "unknown command" };
        return { status: 0, stdout: "help" };
      },
    };
    assert.deepEqual(checkRepository({ root, ...options }), { checked: REQUIRED_FILES.length, failures: [] });
    expectFailure(root, options, () => writeFileSync(join(root, "Documentation/Compatibility/0.3.0.md"), "# Compatibility\n"), "must mention '0.3.0'");
    writeFixture(root);
    expectFailure(root, options, () => writeFileSync(join(root, "Package.swift"), readText(root, "Package.swift").replace('                "GnosticCore",\n', "")), "Atlas target must depend on GnosticCore");
    writeFixture(root);
    expectFailure(root, options, () => writeFileSync(join(root, "Documentation/Architecture/README.md"), "[broken](missing.md)"), "broken local Markdown link");
    writeFixture(root);
    expectFailure(root, options, () => writeFileSync(join(root, "README.md"), "make nonexistent-target\n"), "nonexistent-target");
    writeFixture(root);
    expectFailure(root, options, () => writeFileSync(join(root, "AGENTS.md"), "## Current baseline\n"), "volatile baseline/status");
    writeFixture(root);
    expectFailure(root, options, () => writeFileSync(join(root, "AGENTS.md"), "245 tests\n"), "exact test/suite counts");
    writeFixture(root);
    expectFailure(root, options, () => writeFileSync(join(root, "Documentation/Architecture/exceptions.json"), JSON.stringify({ schemaVersion: 1, exceptions: [{ id: "x" }] })), "exceptions[0].rule");
    writeFixture(root);
    expectFailure(root, options, () => writeFileSync(join(root, "Package.swift"), ".package(path: \"../local\")"), "local-path dependencies");
    writeFixture(root);
    expectFailure(root, options, () => writeFileSync(join(root, "README.md"), "gnostic does-not-exist\n"), "documented CLI command 'gnostic does-not-exist'");
    writeFixture(root);
    assert.throws(
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
    assert.throws(
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

function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfTest) {
    selfTest();
    return;
  }
  try {
    checkRepository({ root: options.root, cliPath: options.cliPath });
    console.log("Documentation checks passed");
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

main();
