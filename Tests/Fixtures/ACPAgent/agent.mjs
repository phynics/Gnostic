import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { appendFile, readFile, writeFile } from "node:fs/promises";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";

const statePath = process.env.GNOSTIC_ACP_FIXTURE_STATE;
assert(statePath, "GNOSTIC_ACP_FIXTURE_STATE is required");
const parentOnlyKey = process.env.GNOSTIC_ACP_FIXTURE_PARENT_ONLY_KEY;
assert(!parentOnlyKey || process.env[parentOnlyKey] === undefined, "unconfigured parent environment leaked to fixture");
if (process.env.GNOSTIC_ACP_FIXTURE_STDERR_SECRET === "1") {
  process.stderr.write(`fixture diagnostic ${process.env.API_TOKEN}\n`);
}
if (process.env.GNOSTIC_ACP_FIXTURE_CHILD_PID_FILE) {
  const child = spawn("/bin/sleep", ["300"], { stdio: "ignore" });
  await writeFile(process.env.GNOSTIC_ACP_FIXTURE_CHILD_PID_FILE, String(child.pid));
}
if (process.env.GNOSTIC_ACP_FIXTURE_PROCESS_PID_FILE) {
  await appendFile(process.env.GNOSTIC_ACP_FIXTURE_PROCESS_PID_FILE, `${process.pid}\n`);
}
if (process.env.GNOSTIC_ACP_FIXTURE_START_COUNT_FILE) {
  await appendFile(process.env.GNOSTIC_ACP_FIXTURE_START_COUNT_FILE, "started\n");
}
const sessions = await loadSessions();
let sessionCounter = 0;
const cancelledSessions = new Set();

const app = acp.agent({ name: "gnostic-deterministic-acp-fixture" })
  .onRequest(acp.methods.agent.initialize, async () => {
    if (process.env.GNOSTIC_ACP_FIXTURE_INITIALIZE_DELAY_MS) {
      await new Promise((resolve) => setTimeout(resolve, Number(process.env.GNOSTIC_ACP_FIXTURE_INITIALIZE_DELAY_MS)));
    }
    return {
      protocolVersion: acp.PROTOCOL_VERSION,
      agentCapabilities: {
        sessionCapabilities: {
          ...(process.env.GNOSTIC_ACP_FIXTURE_NO_LIST === "1" ? {} : { list: {} }),
          resume: {},
          close: {},
        },
      },
      agentInfo: { name: "gnostic-deterministic-acp-fixture", version: "1" },
    };
  })
  .onRequest(acp.methods.agent.session.new, async ({ params }) => {
    let sessionId;
    do {
      sessionId = `fixture-session-${++sessionCounter}`;
    } while (sessions.has(sessionId));
    sessions.set(sessionId, { cwd: params.cwd, title: "Gnostic fixture session" });
    await saveSessions();
    return { sessionId };
  })
  .onRequest(acp.methods.agent.session.list, async ({ params }) => {
    if (process.env.GNOSTIC_ACP_FIXTURE_LIST_REQUEST_FILE) {
      await appendFile(process.env.GNOSTIC_ACP_FIXTURE_LIST_REQUEST_FILE, `${params.cursor ?? "first"}\n`);
    }
    const listedSessions = [...sessions]
      .filter(([, info]) => !params.cwd || info.cwd === params.cwd)
      .map(([sessionId, info]) => ({
        sessionId,
        cwd: info.cwd,
        title: info.title,
        updatedAt: new Date(0).toISOString(),
      }));
    if (process.env.GNOSTIC_ACP_FIXTURE_PAGINATED_LIST === "later-page") {
      return params.cursor
        ? { sessions: listedSessions }
        : { sessions: [], nextCursor: "fixture-page-2" };
    }
    if (process.env.GNOSTIC_ACP_FIXTURE_PAGINATED_LIST === "repeating-cursor") {
      return { sessions: listedSessions, nextCursor: "fixture-repeat" };
    }
    if (process.env.GNOSTIC_ACP_FIXTURE_PAGINATED_LIST === "unbounded") {
      const page = Number(params.cursor?.replace("fixture-page-", "") ?? 0);
      return { sessions: listedSessions, nextCursor: `fixture-page-${page + 1}` };
    }
    return { sessions: listedSessions };
  })
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
  .onNotification(acp.methods.agent.session.cancel, async ({ params }) => {
    cancelledSessions.add(params.sessionId);
    if (process.env.GNOSTIC_ACP_FIXTURE_CANCEL_FILE) {
      await appendFile(process.env.GNOSTIC_ACP_FIXTURE_CANCEL_FILE, `${params.sessionId}\n`);
    }
  })
  .onRequest(acp.methods.agent.session.prompt, async ({ params, client }) => {
    if (!sessions.has(params.sessionId)) throw new Error("unknown fixture session");
    if (process.env.GNOSTIC_ACP_FIXTURE_CRASH_ON_PROMPT === "1") {
      process.stderr.write(`fixture crash diagnostic ${process.env.API_TOKEN}\n`);
      process.exit(19);
    }
    if (process.env.GNOSTIC_ACP_FIXTURE_CRASH_ONCE_FILE) {
      try {
        await readFile(process.env.GNOSTIC_ACP_FIXTURE_CRASH_ONCE_FILE);
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
        await writeFile(process.env.GNOSTIC_ACP_FIXTURE_CRASH_ONCE_FILE, "crashed");
        process.exit(19);
      }
    }
    const promptText = params.prompt
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("");
    if (promptText.includes("[fixture:wait]")) {
      if (process.env.GNOSTIC_ACP_FIXTURE_PROMPT_STARTED_FILE) {
        await appendFile(process.env.GNOSTIC_ACP_FIXTURE_PROMPT_STARTED_FILE, `${params.sessionId}\n`);
      }
      const deadline = Date.now() + 20_000;
      while (!cancelledSessions.has(params.sessionId) && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      if (cancelledSessions.has(params.sessionId)) {
        await client.notify(acp.methods.client.session.update, {
          sessionId: params.sessionId,
          update: {
            sessionUpdate: "agent_message_chunk",
            messageId: "late-after-cancel",
            content: { type: "text", text: "late update" },
          },
        });
        return { stopReason: "cancelled" };
      }
    }
    if (process.env.GNOSTIC_ACP_FIXTURE_PROMPT_DELAY_MS) {
      if (process.env.GNOSTIC_ACP_FIXTURE_PROMPT_STARTED_FILE) {
        await writeFile(process.env.GNOSTIC_ACP_FIXTURE_PROMPT_STARTED_FILE, "started");
      }
      await new Promise((resolve) => setTimeout(resolve, Number(process.env.GNOSTIC_ACP_FIXTURE_PROMPT_DELAY_MS)));
    }
    const prompt = promptText;
    const progressDuration = Number(process.env.GNOSTIC_ACP_FIXTURE_PROMPT_PROGRESS_DURATION_MS ?? 0);
    if (progressDuration > 0) {
      const deadline = Date.now() + progressDuration;
      const progressInterval = Number(process.env.GNOSTIC_ACP_FIXTURE_PROMPT_PROGRESS_INTERVAL_MS ?? 1_000);
      let progressIndex = 0;
      while (Date.now() < deadline) {
        await client.notify(acp.methods.client.session.update, {
          sessionId: params.sessionId,
          update: {
            sessionUpdate: "agent_message_chunk",
            messageId: "fixture-long-turn-progress",
            content: { type: "text", text: "working " },
          },
        });
        progressIndex += 1;
        await new Promise((resolve) => setTimeout(resolve, progressInterval));
      }
      assert(progressIndex > 0, "long prompt must emit progress updates");
    }
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
