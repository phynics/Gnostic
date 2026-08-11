import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";

const binary = process.env.GNOSTIC_ACP_BINARY;
assert(binary, "GNOSTIC_ACP_BINARY is required");
const args = JSON.parse(process.env.GNOSTIC_ACP_ARGS ?? "[]");
const cwd = process.env.GNOSTIC_ACP_CWD ?? "/tmp/gnostic-official-acp-client";
const timelineFile = process.env.GNOSTIC_ACP_TIMELINE_FILE;
const attachedFile = process.env.GNOSTIC_ACP_ATTACHED_FILE;
assert(timelineFile && attachedFile, "official client tool fixture paths are required");
const child = spawn(binary, args, {
  env: process.env,
  stdio: ["pipe", "pipe", "inherit"],
});
const stream = acp.ndJsonStream(
  Writable.toWeb(child.stdin),
  Readable.toWeb(child.stdout),
);

try {
  const updates = [];
  let permissionMode = "allow";
  let permissionSeen;
  let releasePermission;
  await acp
    .client({ name: "gnostic-official-client-fixture" })
    .onNotification(acp.methods.client.session.update, ({ params }) => {
      updates.push(params);
    })
    .onRequest(acp.methods.client.session.requestPermission, async ({ params }) => {
      if (permissionMode === "allow") {
        const option = params.options.find(({ optionId }) => optionId === "allow_once") ?? params.options[0];
        assert(option, "permission request must include an option");
        return { outcome: { outcome: "selected", optionId: option.optionId } };
      }
      permissionSeen?.();
      return new Promise((resolve) => {
        releasePermission = () => resolve({ outcome: { outcome: "cancelled" } });
      });
    })
    .connectWith(stream, async (ctx) => {
      const initialized = await ctx.request(acp.methods.agent.initialize, {
        protocolVersion: acp.PROTOCOL_VERSION,
        clientCapabilities: {},
        clientInfo: { name: "gnostic-official-client-fixture", version: "1" },
      });
      assert.equal(initialized.protocolVersion, acp.PROTOCOL_VERSION);
      assert(initialized.agentCapabilities.sessionCapabilities?.resume);
      assert(initialized.agentCapabilities.sessionCapabilities?.list);
      assert(initialized.agentCapabilities.sessionCapabilities?.close);

      const created = await ctx.request(acp.methods.agent.session.new, {
        cwd,
        mcpServers: [],
      });
      assert(created.sessionId);
      assert.equal(typeof created._meta?.gnosticTimelineID, "string");
      await mkdir(dirname(timelineFile), { recursive: true });
      await writeFile(timelineFile, `${created._meta.gnosticTimelineID}\n`);
      await waitForFile(attachedFile);

      const completed = await ctx.request(acp.methods.agent.session.prompt, {
        sessionId: created.sessionId,
        prompt: [{ type: "text", text: "use the attached workspace" }],
        _meta: { "dev.phynics.pi-acp-client/clientTurnID": "official-client:turn-1" },
      });
      assert.equal(completed.stopReason, "end_turn");
      assert(JSON.stringify(updates).includes("workspace_echo"));

      permissionMode = "cancel";
      const permissionPending = new Promise((resolve) => { permissionSeen = resolve; });
      const cancelledPrompt = ctx.request(acp.methods.agent.session.prompt, {
        sessionId: created.sessionId,
        prompt: [{ type: "text", text: "use the attached workspace again" }],
        _meta: { "dev.phynics.pi-acp-client/clientTurnID": "official-client:turn-2" },
      });
      await permissionPending;
      releasePermission();
      await Promise.resolve();
      await ctx.notify(acp.methods.agent.session.cancel, { sessionId: created.sessionId });
      assert.equal((await cancelledPrompt).stopReason, "cancelled");
      process.stdout.write("official ACP client permission and cancellation passed\n");

      const listed = await ctx.request(acp.methods.agent.session.list, { cwd });
      assert(listed.sessions.some((session) => session.sessionId === created.sessionId));

      await ctx.request(acp.methods.agent.session.close, { sessionId: created.sessionId });
      await ctx.request(acp.methods.agent.session.resume, {
        sessionId: created.sessionId,
        cwd,
        mcpServers: [],
      });
      await ctx.request(acp.methods.agent.session.close, { sessionId: created.sessionId });
    });
} finally {
  child.kill();
}

console.log("official ACP client lifecycle passed");

async function waitForFile(path) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      await readFile(path);
      return;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timed out waiting for ${path}`);
}
