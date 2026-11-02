#!/usr/bin/env node
// Reads a Timeline journal for the T4 acceptance runbook.
//
//   node journal.mjs summary <journal.jsonl>   One line per record.
//   node journal.mjs text <journal.jsonl>      The bytes of agent_message_chunk text.
//
// An `acpUpdate` record stores the Runtime's frame as the exact JSON text the Runtime
// sent (#730), so it can hold a byte order mark, a payload that does not fit its ACP
// type, or text that is not a string. This script reports such a record as unsupported
// and goes on. It never stops at one bad record.

import { readFileSync } from "node:fs";

const [mode, file] = process.argv.slice(2);
if (!["summary", "text"].includes(mode) || !file) {
  console.error("Usage: node journal.mjs summary|text <journal.jsonl>");
  process.exit(2);
}

const stripBOM = (text) => text.replace(/^﻿/, "");
const lines = stripBOM(readFileSync(file, "utf8")).split("\n").filter((line) => line.trim() !== "");

// Returns { update } for a readable ACP update, or { problem } with the reason it is not.
function decodeUpdate(body) {
  const stored = body?.update?.update;
  let frame = stored;
  if (typeof stored === "string") {
    try {
      frame = JSON.parse(stripBOM(stored));
    } catch (error) {
      return { problem: `frame text is not JSON (${error.message})` };
    }
  }
  const update = frame?.params?.update ?? frame;
  if (!update || typeof update !== "object" || Array.isArray(update)) return { problem: "no update object in the frame" };
  return { update };
}

let unsupported = 0;
let total = 0;
let chunks = 0;
for (const [index, line] of lines.entries()) {
  const brace = line.indexOf("{");
  let record;
  try {
    record = JSON.parse(stripBOM(line.slice(Math.max(brace, 0))));
  } catch (error) {
    unsupported += 1;
    console.log([String(index + 1).padStart(3), "unreadable record", `(${error.message})`].join(" "));
    continue;
  }
  const kind = Object.keys(record.payload ?? {})[0] ?? "unknown";
  const body = record.payload?.[kind];
  const sequence = `seq=${record.sequence}`;
  if (mode === "summary") {
    let detail = "";
    if (kind === "acpUpdate") {
      const decoded = decodeUpdate(body);
      if (decoded.problem) {
        unsupported += 1;
        detail = `(unsupported: ${decoded.problem})`;
      } else {
        detail = typeof decoded.update.sessionUpdate === "string" ? decoded.update.sessionUpdate : "(no sessionUpdate)";
      }
    } else {
      detail = (kind === "sessionTransition" ? body?.state
        : kind === "turnCompleted" ? body?.outcome
        : kind === "permissionDecision" ? body?.decision
        : kind === "workspaceAttached" ? body?.scope
        : "") ?? "";
    }
    console.log([String(index + 1).padStart(3), sequence, kind, detail].filter(Boolean).join(" "));
    continue;
  }
  if (kind !== "acpUpdate") continue;
  const decoded = decodeUpdate(body);
  if (decoded.problem) {
    unsupported += 1;
    console.log(`journal ${sequence} unsupported frame, not counted: ${decoded.problem}`);
    continue;
  }
  if (decoded.update.sessionUpdate !== "agent_message_chunk") continue;
  const blocks = Array.isArray(decoded.update.content) ? decoded.update.content : [decoded.update.content];
  if (!blocks.every((block) => typeof block?.text === "string")) {
    unsupported += 1;
    console.log(`journal ${sequence} unsupported agent_message_chunk, not counted: text is not a string`);
    continue;
  }
  const bytes = blocks.reduce((sum, block) => sum + Buffer.byteLength(block.text), 0);
  total += bytes;
  chunks += 1;
  console.log(`journal ${sequence} agent_message_chunk ${bytes} bytes`);
}
if (mode === "text") console.log(`journal: agent text ${total} bytes in ${chunks} chunks`);
if (unsupported > 0) console.log(`journal: ${unsupported} record(s) reported as unsupported`);
