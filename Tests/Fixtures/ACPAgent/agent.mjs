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
      sessionCapabilities: {
        ...(process.env.GNOSTIC_ACP_FIXTURE_NO_LIST === "1" ? {} : { list: {} }),
        resume: {},
        close: {},
      },
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
  .onRequest(acp.methods.agent.session.list, ({ params }) => ({
    sessions: [...sessions].filter(([, info]) => !params.cwd || info.cwd === params.cwd).map(([sessionId, info]) => ({
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
    if (process.env.GNOSTIC_ACP_FIXTURE_CLOSE_ERROR === "1") {
      throw new Error("fixture close error");
    }
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

    if (process.env.GNOSTIC_ACP_FIXTURE_PERMISSION === "1") {
      const permission = await client.request(acp.methods.client.session.requestPermission, {
        sessionId: params.sessionId,
        toolCall: {
          toolCallId: "fixture-permission-tool",
          title: "Inspect fixture input",
          kind: "read",
          status: "pending",
        },
        options: process.env.GNOSTIC_ACP_FIXTURE_PERMISSION_UNSUPPORTED === "1"
          ? [
              { optionId: "allow-always", name: "Allow always", kind: "allow_always" },
              { optionId: "reject-once", name: "Reject once", kind: "reject_once" },
            ]
          : [
              { optionId: "allow-once", name: "Allow once", kind: "allow_once" },
              { optionId: "reject-once", name: "Reject once", kind: "reject_once" },
            ],
      });
      const outcome = process.env.GNOSTIC_ACP_FIXTURE_PERMISSION_OUTCOME ?? "selected:allow-once";
      if (outcome === "selected:allow-once") {
        assert.deepEqual(permission.outcome, { outcome: "selected", optionId: "allow-once" });
      } else if (outcome === "selected:reject-once") {
        assert.deepEqual(permission.outcome, { outcome: "selected", optionId: "reject-once" });
      } else {
        assert.deepEqual(permission.outcome, { outcome: "cancelled" });
      }
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
