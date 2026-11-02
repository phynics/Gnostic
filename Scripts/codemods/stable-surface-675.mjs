#!/usr/bin/env node
// Applies the #675 renames and moves described in stable-surface-675.json.
//
//   node Scripts/codemods/stable-surface-675.mjs            apply
//   node Scripts/codemods/stable-surface-675.mjs --check    exit 1 when work remains
//
// Idempotent. A rerun after a partial run converges to the same tree. The tool
// renames whole-word type names only. It never edits a string literal's
// content differently from code, so run `git diff` for wire-visible text.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..", "..");
const config = JSON.parse(fs.readFileSync(path.join(repo, "Scripts/codemods/stable-surface-675.json"), "utf8"));
const check = process.argv.includes("--check");
let pending = 0;

function swiftFiles(root) {
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === "node_modules" || entry.name === ".build") continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".swift")) out.push(full);
    }
  };
  walk(path.join(repo, root));
  return out;
}

const names = Object.keys(config.types).sort((a, b) => b.length - a.length);
const pattern = new RegExp(`\\b(${names.join("|")})\\b`, "g");

// 1. Moves first, while the old names still locate the symbols.
for (const move of config.moves) {
  const from = path.join(repo, move.from);
  const to = path.join(repo, move.to);
  if (move.whole) {
    if (fs.existsSync(from)) {
      pending += 1;
      if (!check) {
        execFileSync("git", ["mv", move.from, move.to], { cwd: repo });
        stripImport(to, "GnosticProtocol");
      }
    }
    continue;
  }
  if (!fs.existsSync(from)) continue;
  const lines = fs.readFileSync(from, "utf8").split("\n");
  const extracted = [];
  const kept = [];
  let i = 0;
  let found = 0;
  const declaration = (symbol) =>
    new RegExp(`^(public |package |internal )?(final )?(struct|enum|class|actor|protocol|typealias) ${symbol}\\b`);
  while (i < lines.length) {
    const hit = move.symbols.find((symbol) => declaration(symbol).test(lines[i]));
    if (!hit) { kept.push(lines[i]); i += 1; continue; }
    // Pull the doc comment and attributes already pushed onto `kept`.
    let leading = [];
    while (kept.length > 0 && /^(\/\/\/|@)/.test(kept[kept.length - 1])) leading.unshift(kept.pop());
    let end = i;
    if (!/^typealias|^public typealias/.test(lines[i])) {
      while (end < lines.length && lines[end] !== "}") end += 1;
    }
    extracted.push([...leading, ...lines.slice(i, end + 1)].join("\n"));
    found += 1;
    i = end + 1;
    while (i < lines.length && lines[i] === "") i += 1; // drop the blank gap that followed
    if (kept.length > 0 && kept[kept.length - 1] !== "") kept.push("");
  }
  if (found === 0) continue;
  pending += found;
  if (check) continue;
  const header = fs.existsSync(to)
    ? fs.readFileSync(to, "utf8").replace(/\n+$/, "") + "\n\n"
    : "// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.\n\nimport Foundation\n\n";
  fs.writeFileSync(to, header + extracted.join("\n\n") + "\n");
  fs.writeFileSync(from, kept.join("\n").replace(/\n{3,}/g, "\n\n").replace(/\n+$/, "") + "\n");
}

function stripImport(file, module) {
  const text = fs.readFileSync(file, "utf8").replace(new RegExp(`^import ${module}\\n`, "m"), "");
  fs.writeFileSync(file, text);
}

// 2. Whole-word renames.
for (const root of config.roots) {
  for (const file of swiftFiles(root)) {
    const original = fs.readFileSync(file, "utf8");
    if (!pattern.test(original)) { pattern.lastIndex = 0; continue; }
    pattern.lastIndex = 0;
    pending += 1;
    if (!check) fs.writeFileSync(file, original.replace(pattern, (name) => config.types[name]));
  }
}

if (check && pending > 0) {
  console.error(`stable-surface-675: ${pending} rename or move step(s) remain`);
  process.exit(1);
}
console.log(check ? "stable-surface-675: nothing left to do" : "stable-surface-675: applied");
