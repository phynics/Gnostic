#!/usr/bin/env node
// A scripted ACP v2 client for the T4 acceptance runbook.
//
// It spawns `gnostic acp` (everything after `--`) and speaks ACP v2 over its
// stdio. It prints one stable line per event, so a drill can compare the output
// with the runbook. It answers a permission request as `--permission` says:
// `approve`, `deny`, `cancel` (answer with the `cancelled` outcome), or `ignore`
// (never answer).
//
// Usage:
//   node client.mjs [options] -- <gnostic> acp --runtime <id> --node <id> ...
//
// Options:
//   --prompt <text>          Send this prompt. Repeat the option for more Turns.
//   --client-turn-id <id>    Name the first prompt's Turn, so a retry is idempotent.
//   --permission <answer>    approve | deny | cancel | ignore. Default: approve.
//   --cwd <path>             Session cwd. Default: the current directory.
//   --state-file <path>      Write {sessionId, timelineId, cwd} here after session/new.
//   --resume <path>          Resume the session in this state file instead of session/new.
//   --on-session <command>   Run this shell command after the session is ready.
//                            It sees T4_SESSION_ID and T4_SESSION_TIMELINE_ID.
//   --after-first-turn <command>
//                            Run this shell command after the first Turn ends,
//                            with the same environment as --on-session.
//   --timeout-ms <n>         Wait this long for each Turn to end. Default: 60000.
//   --print-max <n>          Print at most n characters of each text. Default: 160.
//   --hold-open-ms <n>       After the last Turn, wait before closing the session.
//   --no-close               Leave the session open on exit.
//   --elapsed                Start each line with the seconds since the client started.
//
// Exit status: 0 when every prompt ended with an idle update, 1 when a prompt
// failed or timed out, 2 for a usage error.

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { readFile, writeFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk/experimental/v2";

const turnIDMetadataKey = "dev.phynics.pi-acp-client/clientTurnID";
const separator = process.argv.indexOf("--");
if (separator < 0 || separator === process.argv.length - 1) usage("Put the gnostic acp command after `--`.");
const command = process.argv.slice(separator + 1);

let options;
try {
  options = parseArgs({
    args: process.argv.slice(2, separator),
    options: {
      prompt: { type: "string", multiple: true },
      "client-turn-id": { type: "string" },
      permission: { type: "string", default: "approve" },
      cwd: { type: "string", default: process.cwd() },
      "state-file": { type: "string" },
      resume: { type: "string" },
      "on-session": { type: "string" },
      "after-first-turn": { type: "string" },
      "timeout-ms": { type: "string", default: "60000" },
      "print-max": { type: "string", default: "160" },
      "hold-open-ms": { type: "string", default: "0" },
      "no-close": { type: "boolean", default: false },
      elapsed: { type: "boolean", default: false },
    },
  }).values;
} catch (error) {
  usage(error.message);
}
if (!["approve", "deny", "cancel", "ignore"].includes(options.permission)) {
  usage("--permission must be approve, deny, cancel, or ignore.");
}
const started = Date.now();
const prompts = options.prompt ?? [];
const timeoutMs = Number(options["timeout-ms"]);
const printMax = Number(options["print-max"]);

if (options.elapsed) {
  const log = console.log;
  console.log = (...parts) => log(`[+${String(Math.round((Date.now() - started) / 1000)).padStart(3)}s]`, ...parts);
}

const child = spawn(command[0], command.slice(1), { stdio: ["pipe", "pipe", "inherit"] });
child.on("error", (error) => {
  console.log(`spawn failed: ${error.message}`);
  process.exit(1);
});
const stream = acp.ndJsonStream(Writable.toWeb(child.stdin), Readable.toWeb(child.stdout));

const updates = [];
let permissionRequests = 0;
let failed = false;

try {
  await acp
    .client({ name: "gnostic-t4-acceptance-client" })
    .onNotification(acp.methods.client.session.update, ({ params }) => {
      updates.push(params);
      report(params.update);
    })
    .onRequest(acp.methods.client.session.requestPermission, async ({ params }) => {
      permissionRequests += 1;
      const optionIDs = params.options.map(({ optionId }) => optionId).join(",");
      const seconds = ((Date.now() - started) / 1000).toFixed(0);
      console.log(`permission request ${permissionRequests}: ${quote(params.title)} options=${optionIDs}`);
      if (options.permission === "ignore") {
        console.log(`permission request ${permissionRequests}: not answering (waiting from t=${seconds}s)`);
        return new Promise(() => {});
      }
      if (options.permission === "cancel") {
        console.log(`permission request ${permissionRequests}: answered cancelled`);
        return { outcome: { outcome: "cancelled" } };
      }
      const wanted = options.permission === "approve" ? "allow_once" : "reject_once";
      const option = params.options.find(({ kind }) => kind === wanted);
      assert(option, `the permission request offers no ${wanted} option`);
      console.log(`permission request ${permissionRequests}: answered ${option.optionId}`);
      return { outcome: { outcome: "selected", optionId: option.optionId } };
    })
    .connectWith(stream, async (ctx) => {
      const initialized = await ctx.request(acp.methods.agent.initialize, {
        protocolVersion: acp.PROTOCOL_VERSION,
        capabilities: {},
        info: { name: "gnostic-t4-acceptance-client", version: "1" },
      });
      console.log(`initialize: protocolVersion=${initialized.protocolVersion}`);

      let session;
      if (options.resume) {
        session = JSON.parse(await readFile(options.resume, "utf8"));
        await ctx.request(acp.methods.agent.session.resume, {
          sessionId: session.sessionId,
          cwd: session.cwd,
          mcpServers: [],
        });
        console.log(`session/resume: sessionId=${session.sessionId} timeline=${session.timelineId}`);
      } else {
        const created = await ctx.request(acp.methods.agent.session.new, { cwd: options.cwd, mcpServers: [] });
        session = {
          sessionId: created.sessionId,
          timelineId: created._meta?.gnosticTimelineID,
          cwd: options.cwd,
        };
        console.log(`session/new: sessionId=${session.sessionId} timeline=${session.timelineId}`);
        if (options["state-file"]) await writeFile(options["state-file"], JSON.stringify(session));
      }

      const runHook = (label, hook) => {
        const result = spawnSync("sh", ["-c", hook], {
          encoding: "utf8",
          env: { ...process.env, T4_SESSION_ID: session.sessionId, T4_SESSION_TIMELINE_ID: session.timelineId },
        });
        process.stdout.write(result.stdout ?? "");
        process.stderr.write(result.stderr ?? "");
        console.log(`${label}: exit ${result.status}`);
        if (result.status !== 0) throw new Error(`the ${label} command failed`);
      };
      if (options["on-session"]) runHook("on-session", options["on-session"]);

      for (const [index, text] of prompts.entries()) {
        const start = updates.length;
        const clientTurnID = index === 0 ? options["client-turn-id"] : undefined;
        console.log(`session/prompt ${index + 1}: ${quote(text)}${clientTurnID ? ` clientTurnID=${clientTurnID}` : ""}`);
        try {
          const answer = await withTimeout(ctx.request(acp.methods.agent.session.prompt, {
            sessionId: session.sessionId,
            prompt: [{ type: "text", text }],
            ...(clientTurnID ? { _meta: { [turnIDMetadataKey]: clientTurnID } } : {}),
          }), `the session/prompt response did not arrive within ${timeoutMs} ms`);
          console.log(`session/prompt ${index + 1}: accepted messageId=${answer.messageId}`);
          await waitForIdle(start);
          if (index === 0 && options["after-first-turn"]) runHook("after-first-turn", options["after-first-turn"]);
        } catch (error) {
          failed = true;
          const code = error?.code ?? error?.data?.code ?? "";
          console.log(`session/prompt ${index + 1}: FAILED code=${code} message=${quote(error?.message ?? String(error))}`
            + (error?.data ? ` data=${JSON.stringify(error.data)}` : ""));
        }
      }

      if (Number(options["hold-open-ms"]) > 0) await sleep(Number(options["hold-open-ms"]));
      if (!options["no-close"] && !failed) {
        await ctx.request(acp.methods.agent.session.close, { sessionId: session.sessionId });
        console.log("session/close: ok");
      }
    });
} catch (error) {
  failed = true;
  console.log(`connection ended: ${error?.message ?? error}`);
} finally {
  console.log(`summary: permissionRequests=${permissionRequests} failed=${failed} elapsedSeconds=${Math.round((Date.now() - started) / 1000)}`);
  child.kill("SIGTERM");
  if (child.exitCode === null && child.signalCode === null) await once(child, "close");
}
process.exit(failed ? 1 : 0);

function report(update) {
  const kind = update?.sessionUpdate;
  let detail = "";
  if (kind === "state_update") {
    detail = `state=${update.state}${update.stopReason ? ` stopReason=${update.stopReason}` : ""}`;
  } else if (kind === "agent_message_chunk" || kind === "agent_message") {
    detail = quote(textOf(update.content));
  } else if (kind === "user_message") {
    detail = quote(textOf(update.content));
  } else if (kind === "tool_call_update" || kind === "tool_call") {
    detail = `${update.name ?? update.title ?? ""} status=${update.status ?? ""}`;
  }
  console.log(`update ${kind}${detail ? `: ${detail}` : ""}`);
}

function textOf(content) {
  const blocks = Array.isArray(content) ? content : [content];
  return blocks.map((block) => block?.text ?? "").join("");
}

function quote(text) {
  const flat = String(text).replaceAll("\n", "\\n");
  const cut = flat.length > printMax ? `${flat.slice(0, printMax)}…(${flat.length} chars)` : flat;
  return JSON.stringify(cut);
}

async function waitForIdle(start) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const idle = updates.slice(start).find(({ update }) => update?.sessionUpdate === "state_update" && update.state === "idle");
    if (idle) return;
    await sleep(25);
  }
  failed = true;
  console.log(`session/prompt: TIMED OUT after ${timeoutMs} ms without an idle update`);
}

function withTimeout(promise, message) {
  let timer;
  const expiry = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), timeoutMs); });
  return Promise.race([promise, expiry]).finally(() => clearTimeout(timer));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function usage(message) {
  console.error(`client.mjs: ${message}`);
  console.error("Usage: node client.mjs [--prompt <text>]... [options] -- <gnostic> acp ...");
  process.exit(2);
}
