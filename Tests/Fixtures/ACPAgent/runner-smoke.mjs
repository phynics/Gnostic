import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { writeFile } from "node:fs/promises";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk/experimental/v2";

const binary = process.env.GNOSTIC_ACP_CLIENT_BINARY;
const config = process.env.GNOSTIC_ACP_CLIENT_CONFIG;
const namespace = process.env.GNOSTIC_ACP_CLIENT_NAMESPACE;
const stderrFile = process.env.GNOSTIC_ACP_CLIENT_STDERR_FILE;
assert(binary && config && namespace && stderrFile, "runner smoke client configuration is required");

const child = spawn(binary, [
  "acp", "--config", config,
  "--host", "127.0.0.1", "--port", "1883", "--namespace", namespace,
  "--runtime", "e51d0000-0000-4000-8000-000000000002",
  "--node", "e51d0000-0000-4000-8000-000000000001",
], { stdio: ["pipe", "pipe", "pipe"] });
const clientStderr = [];
child.stderr.on("data", (chunk) => clientStderr.push(chunk));
const stream = acp.ndJsonStream(Writable.toWeb(child.stdin), Readable.toWeb(child.stdout));

try {
  const updates = [];
  await acp.client({ name: "gnostic-runner-smoke-client" })
    .onNotification(acp.methods.client.session.update, ({ params }) => updates.push(params))
    .connectWith(stream, async (ctx) => {
      const initialized = await ctx.request(acp.methods.agent.initialize, {
        protocolVersion: acp.PROTOCOL_VERSION,
        capabilities: {},
        info: { name: "gnostic-runner-smoke-client", version: "1" },
      });
      assert.equal(initialized.protocolVersion, acp.PROTOCOL_VERSION);
      assert(initialized.capabilities.session);

      const created = await ctx.request(acp.methods.agent.session.new, {
        cwd: process.env.GNOSTIC_ACP_CLIENT_STATE ?? "/tmp/gnostic-runner-smoke",
        mcpServers: [],
      });
      assert(created.sessionId);
      assert.equal(typeof created._meta?.gnosticTimelineID, "string");

      const start = updates.length;
      const prompted = await ctx.request(acp.methods.agent.session.prompt, {
        sessionId: created.sessionId,
        prompt: [{ type: "text", text: "runner smoke turn" }],
      });
      assert(prompted.messageId);
      await waitForIdle(updates, start);
      assert(JSON.stringify(updates.slice(start)).includes("reply: runner smoke turn"));

      await ctx.request(acp.methods.agent.session.close, { sessionId: created.sessionId });
      process.stdout.write("runner ACP initialization, session, and turn passed\n");
    });
} finally {
  child.kill("SIGTERM");
  if (child.exitCode === null && child.signalCode === null) await once(child, "close");
  await writeFile(stderrFile, Buffer.concat(clientStderr));
}

async function waitForIdle(updates, start) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (updates.slice(start).some(({ update }) =>
      update?.sessionUpdate === "state_update" && update.state === "idle" && update.stopReason === "end_turn")) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`timed out waiting for completed ACP turn: ${JSON.stringify(updates.slice(start))}`);
}
