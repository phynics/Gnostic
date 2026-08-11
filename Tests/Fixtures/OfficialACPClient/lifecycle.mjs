import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";

const binary = process.env.GNOSTIC_ACP_BINARY;
assert(binary, "GNOSTIC_ACP_BINARY is required");
const args = JSON.parse(process.env.GNOSTIC_ACP_ARGS ?? "[]");
const cwd = process.env.GNOSTIC_ACP_CWD ?? "/tmp/gnostic-official-acp-client";
const child = spawn(binary, args, {
  env: process.env,
  stdio: ["pipe", "pipe", "inherit"],
});
const stream = acp.ndJsonStream(
  Writable.toWeb(child.stdin),
  Readable.toWeb(child.stdout),
);

try {
  await acp
    .client({ name: "gnostic-official-client-fixture" })
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
