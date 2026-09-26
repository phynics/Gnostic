import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";

const statePath = process.env.GNOSTIC_ACP_FIXTURE_STATE;
assert(statePath, "GNOSTIC_ACP_FIXTURE_STATE is required");
const sessions = await loadSessions();
let sessionCounter = 0;

const app = acp.agent({ name: "gnostic-deterministic-acp-fixture" })
  .onRequest(acp.methods.agent.initialize, () => ({
    protocolVersion: acp.PROTOCOL_VERSION,
    agentCapabilities: {
      sessionCapabilities: { list: {}, resume: {}, close: {} },
    },
    agentInfo: { name: "gnostic-deterministic-acp-fixture", version: "1" },
  }))
  .onRequest(acp.methods.agent.session.new, async ({ params }) => {
    let sessionId;
    do {
      sessionId = `fixture-session-${++sessionCounter}`;
    } while (sessions.has(sessionId));
    sessions.set(sessionId, { cwd: params.cwd, title: "Gnostic fixture session" });
    await saveSessions();
    return { sessionId };
  })
  .onRequest(acp.methods.agent.session.list, () => ({
    sessions: [...sessions].map(([sessionId, info]) => ({
      sessionId,
      cwd: info.cwd,
      title: info.title,
      updatedAt: new Date(0).toISOString(),
    })),
  }))
  .onRequest(acp.methods.agent.session.resume, ({ params }) => {
    if (!sessions.has(params.sessionId)) throw new Error("unknown fixture session");
    return {};
  })
  .onRequest(acp.methods.agent.session.close, async ({ params }) => {
    sessions.delete(params.sessionId);
    await saveSessions();
    return {};
  })
  .onRequest(acp.methods.agent.session.prompt, async ({ params, client }) => {
    if (!sessions.has(params.sessionId)) throw new Error("unknown fixture session");
    const prompt = params.prompt
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("");
    if (process.env.GNOSTIC_ACP_FIXTURE_TERMINAL_ERROR === "1" || prompt.includes("[fixture:terminal-error]")) {
      throw new Error("fixture terminal error");
    }

    const messageId = "fixture-message-1";
    await client.notify(acp.methods.client.session.update, {
      sessionId: params.sessionId,
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId,
        content: { type: "text", text: "fixture " },
      },
    });
    await client.notify(acp.methods.client.session.update, {
      sessionId: params.sessionId,
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId,
        content: { type: "text", text: `reply: ${prompt}` },
      },
    });
    await client.notify(acp.methods.client.session.update, {
      sessionId: params.sessionId,
      update: {
        sessionUpdate: "tool_call",
        toolCallId: "fixture-tool-1",
        title: "Inspect fixture input",
        name: "fixture.inspect",
        kind: "read",
        status: "pending",
      },
    });
    await client.notify(acp.methods.client.session.update, {
      sessionId: params.sessionId,
      update: {
        sessionUpdate: "tool_call_update",
        toolCallId: "fixture-tool-1",
        status: "completed",
        title: "Inspect fixture input",
        rawOutput: { inspected: true },
      },
    });

    const stopReason = prompt.includes("[fixture:max-tokens]") ? "max_tokens"
      : prompt.includes("[fixture:refusal]") ? "refusal"
      : "end_turn";
    return { stopReason };
  });

const stream = acp.ndJsonStream(
  Writable.toWeb(process.stdout),
  Readable.toWeb(process.stdin),
);
app.connect(stream);

async function loadSessions() {
  try {
    const parsed = JSON.parse(await readFile(statePath, "utf8"));
    return new Map(Object.entries(parsed));
  } catch (error) {
    if (error?.code === "ENOENT") return new Map();
    throw error;
  }
}

async function saveSessions() {
  await writeFile(statePath, JSON.stringify(Object.fromEntries(sessions)));
}
