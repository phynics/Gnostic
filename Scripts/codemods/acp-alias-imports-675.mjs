#!/usr/bin/env node
// D19 (#675): GnosticProtocol no longer re-exports the ACP wire types through
// 87 public typealiases. Every file that names one of them now imports
// GnosticACPWire itself.
//
//   node Scripts/codemods/acp-alias-imports-675.mjs            add the imports
//   node Scripts/codemods/acp-alias-imports-675.mjs --check    exit 1 when one is missing
//
// The alias list is read from the last commit that still had the exports file,
// so the tool stays rerunnable after the file is deleted. It prints the SwiftPM
// targets whose sources now import GnosticACPWire, so Package.swift can list
// the dependency.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..", "..");
const check = process.argv.includes("--check");
const exportsPath = "Sources/GnosticProtocol/GnosticACPWireExports.swift";
const base = process.env.ALIAS_BASE_REF ?? "origin/main";
const exportsText = execFileSync("git", ["show", `${base}:${exportsPath}`], { cwd: repo, encoding: "utf8" });
const names = [...exportsText.matchAll(/typealias (\w+) =/g)].map((match) => match[1]);
if (names.length !== 87) throw new Error(`expected 87 aliases, found ${names.length}`);
const usage = new RegExp(`\\b(${names.join("|")})\\b`);

function swiftFiles(root) {
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (["node_modules", ".build"].includes(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".swift")) out.push(full);
    }
  };
  walk(path.join(repo, root));
  return out;
}

const targets = new Set();
let missing = 0;
for (const file of [...swiftFiles("Sources"), ...swiftFiles("Tests")]) {
  const relative = path.relative(repo, file);
  if (relative.startsWith("Sources/GnosticACPWire/") || relative === exportsPath) continue;
  const text = fs.readFileSync(file, "utf8");
  const code = text.replace(/\/\/.*$/gm, "").replace(/"(?:[^"\\\n]|\\.)*"/g, '""');
  if (!usage.test(code)) continue;
  const parts = relative.split("/");
  targets.add(parts[0] === "Tests" && parts[1] === "Support" ? `${parts[0]}/${parts[1]}/${parts[2]}` : `${parts[0]}/${parts[1]}`);
  if (/^import GnosticACPWire$/m.test(text)) continue;
  missing += 1;
  if (check) continue;
  const lines = text.split("\n");
  const importAt = lines
    .map((line, index) => ({ line, index }))
    .filter(({ line }) => /^(@testable |@_exported )?import \w+/.test(line));
  const module = (line) => line.replace(/^(@testable |@_exported )?import /, "");
  let insertAt;
  if (importAt.length === 0) {
    insertAt = lines.findIndex((line) => line.trim() === "") + 1;
    lines.splice(insertAt, 0, "import GnosticACPWire", "");
  } else {
    const after = importAt.filter(({ line }) => module(line).localeCompare("GnosticACPWire") < 0);
    insertAt = after.length === 0 ? importAt[0].index : after[after.length - 1].index + 1;
    lines.splice(insertAt, 0, "import GnosticACPWire");
  }
  fs.writeFileSync(file, lines.join("\n"));
}
console.log(`files importing GnosticACPWire by target: ${[...targets].sort().join(", ")}`);
if (check && missing > 0) {
  console.error(`acp-alias-imports-675: ${missing} file(s) lack import GnosticACPWire`);
  process.exit(1);
}
