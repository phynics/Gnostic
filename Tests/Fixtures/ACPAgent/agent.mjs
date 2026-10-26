import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { appendFile, readFile, writeFile } from "node:fs/promises";
import { appendFileSync } from "node:fs";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk/experimental/v2";

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
if (process.env.GNOSTIC_ACP_FIXTURE_PROCESS_EXIT_FILE) {
  process.on("exit", () => appendFileSync(process.env.GNOSTIC_ACP_FIXTURE_PROCESS_EXIT_FILE, "exited\n"));
}
if (process.env.GNOSTIC_ACP_FIXTURE_START_COUNT_FILE) {
  await appendFile(process.env.GNOSTIC_ACP_FIXTURE_START_COUNT_FILE, "started\n");
}
const sessions = await loadSessions();
let sessionCounter = 0;
let sessionListCount = 0;
const cancelledSessions = new Set();

const app = acp.agent({ name: "gnostic-deterministic-acp-fixture" })
  .onRequest(acp.methods.agent.initialize, async () => {
    if (process.env.GNOSTIC_ACP_FIXTURE_INITIALIZE_FILE) {
      await appendFile(process.env.GNOSTIC_ACP_FIXTURE_INITIALIZE_FILE, "initialized\n");
    }
    if (process.env.GNOSTIC_ACP_FIXTURE_INITIALIZE_DELAY_MS) {
      await new Promise((resolve) => setTimeout(resolve, Number(process.env.GNOSTIC_ACP_FIXTURE_INITIALIZE_DELAY_MS)));
    }
    const extraCapabilities = JSON.parse(process.env.GNOSTIC_ACP_FIXTURE_EXTRA_CAPABILITIES ?? "{}");
    const capabilities = {
      ...extraCapabilities,
      ...(process.env.GNOSTIC_ACP_FIXTURE_NO_LIST === "1" ? {} : {
        session: {
          ...extraCapabilities.session,
          ...(process.env.GNOSTIC_ACP_FIXTURE_MCP === "1" ? { mcp: { http: {} } } : {}),
        },
      }),
    };
    return {
      protocolVersion: Number(process.env.GNOSTIC_ACP_FIXTURE_PROTOCOL_VERSION ?? acp.PROTOCOL_VERSION),
      ...(Object.keys(capabilities).length === 0 ? {} : { capabilities }),
      info: { name: "gnostic-deterministic-acp-fixture", version: "1" },
    };
  })
  .onRequest(acp.methods.agent.session.new, async ({ params }) => {
    let sessionId;
    do {
      sessionId = `fixture-session-${++sessionCounter}`;
    } while (sessions.has(sessionId));
    const session = { cwd: params.cwd, title: "Gnostic fixture session" };
    if (params.mcpServers?.length) session.mcpServers = params.mcpServers;
    sessions.set(sessionId, session);
    if (process.env.GNOSTIC_ACP_FIXTURE_NEW_SESSION_FILE) {
      await appendFile(process.env.GNOSTIC_ACP_FIXTURE_NEW_SESSION_FILE, `${sessionId}\n`);
    }
    await saveSessions();
    return { sessionId };
  })
  .onRequest(acp.methods.agent.session.list, async ({ params }) => {
    if (process.env.GNOSTIC_ACP_FIXTURE_LIST_REQUEST_FILE) {
      await appendFile(process.env.GNOSTIC_ACP_FIXTURE_LIST_REQUEST_FILE, `${params.cursor ?? "first"}\n`);
    }
    if (process.env.GNOSTIC_ACP_FIXTURE_LIST_EXIT_AFTER) {
      sessionListCount += 1;
      if (sessionListCount >= Number(process.env.GNOSTIC_ACP_FIXTURE_LIST_EXIT_AFTER)) {
        process.exit(19);
      }
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
  .onRequest(acp.methods.agent.session.resume, async ({ params }) => {
    if (process.env.GNOSTIC_ACP_FIXTURE_RESUME_REQUEST_FILE) {
      await appendFile(process.env.GNOSTIC_ACP_FIXTURE_RESUME_REQUEST_FILE, `${JSON.stringify(params)}\n`);
    }
    if (process.env.GNOSTIC_ACP_FIXTURE_ASSERT_AMBIGUOUS_JOURNAL_FILE) {
      const journal = await readFile(process.env.GNOSTIC_ACP_FIXTURE_TIMELINE_JOURNAL_FILE, "utf8");
      const priorSessionRecord = journal.trim().split("\n").reverse()
        .find((record) => record.includes(JSON.stringify(params.sessionId)));
      const state = priorSessionRecord?.includes('"ambiguous"') ? "ambiguous" : "not-ambiguous";
      await writeFile(process.env.GNOSTIC_ACP_FIXTURE_ASSERT_AMBIGUOUS_JOURNAL_FILE, `${state}\n`);
    }
    if (process.env.GNOSTIC_ACP_FIXTURE_EXIT_ON_RESUME === "1") process.exit(19);
    if (process.env.GNOSTIC_ACP_FIXTURE_INTERNAL_RESUME_ERROR === "1") {
      throw acp.RequestError.internalError({ details: "fixture resume failed" }, "Internal error");
    }
    if (process.env.GNOSTIC_ACP_FIXTURE_REJECT_RESUME === "1") {
      throw acp.RequestError.invalidParams({ details: "unknown fixture session" }, "Session cannot be resumed");
    }
    if (!sessions.has(params.sessionId)) throw new Error("unknown fixture session");
    const session = sessions.get(params.sessionId);
    if (params.mcpServers?.length) session.mcpServers = params.mcpServers;
    else delete session.mcpServers;
    sessions.set(params.sessionId, session);
    await saveSessions();
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
    if (process.env.GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE) {
      await appendFile(process.env.GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE, `${params.sessionId}\n`);
    }
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
    if (promptText.includes("[fixture:workspace-tool]") || promptText.includes("[fixture:workspace-tool-rejected]")) {
      const server = sessions.get(params.sessionId)?.mcpServers?.[0];
      assert(server?.url && server.headers, "Gnostic did not provide an authenticated MCP server");
      const protocolVersion = "2025-03-26";
      const publicFailureCategories = new Map([
        ["invalidWorkspaceInvocationPayload", "owner-invalid-invocation"],
        ["notRunning", "owner-not-running"],
        ["workspaceInvocationFailed", "owner-invocation-failed"],
        ["workspaceNotAttached", "owner-workspace-not-attached"],
        ["workspacePermissionRequired", "owner-permission-required"],
        ["workspaceToolNotAdvertised", "owner-tool-not-advertised"],
        ["workspaceUnavailable", "owner-workspace-unavailable"],
      ]);
      const gatewayFailureCategories = new Map([
        ["Workspace tool is not attached or is unavailable.", "gateway-tool-unavailable"],
        ["Workspace is not attached to this Timeline.", "gateway-workspace-not-attached"],
        ["Workspace tool requires an active, approved Turn.", "gateway-turn-not-approved"],
        ["Workspace permission could not be committed.", "gateway-permission-commit-failed"],
        ["Workspace tool permission was not approved.", "gateway-permission-not-approved"],
        ["Workspace attachment or availability changed before dispatch.", "gateway-attachment-changed"],
      ]);
      const errorCategory = (error) => {
        const publicFailure = (() => {
          if (error?.data && typeof error.data === "object") return error.data;
          if (typeof error?.message !== "string") return undefined;
          try {
            const parsed = JSON.parse(error.message);
            return parsed && typeof parsed === "object" ? parsed : undefined;
          } catch {
            return undefined;
          }
        })();
        if (typeof publicFailure?.reasonCode === "string") {
          const category = publicFailureCategories.get(publicFailure.reasonCode);
          if (category) return category;
        }
        if (typeof error?.message === "string") {
          return gatewayFailureCategories.get(error.message) ?? "unclassified";
        }
        return "unclassified";
      };
      const mcp = async (id, method, requestParams = {}, allowError = false) => {
        const headers = {
          "content-type": "application/json",
          accept: "application/json, text/event-stream",
          ...Object.fromEntries(server.headers.map(({ name, value }) => [name, value])),
        };
        if (method !== "initialize") headers["MCP-Protocol-Version"] = protocolVersion;
        const diagnosticsPath = process.env.GNOSTIC_ACP_FIXTURE_MCP_DIAGNOSTICS_FILE;
        const recordDiagnostic = async (fields) => {
          if (!diagnosticsPath) return;
          await appendFile(diagnosticsPath, `${JSON.stringify({ method, ...fields })}\n`);
        };
        let response;
        try {
          response = await fetch(server.url, {
            method: "POST",
            headers,
            body: JSON.stringify({ jsonrpc: "2.0", id, method, params: requestParams }),
          });
        } catch (error) {
          await recordDiagnostic({ outcome: "no-response", errorName: error?.name ?? "unknown" });
          throw error;
        }
        if (response.status !== 200) {
          await recordDiagnostic({ outcome: "http-error", httpStatus: response.status });
          assert.equal(response.status, 200, `MCP ${method} returned HTTP ${response.status}`);
        }
        let message;
        try {
          message = await response.json();
        } catch (error) {
          await recordDiagnostic({
            outcome: "invalid-response",
            httpStatus: response.status,
            errorName: error?.name ?? "unknown",
          });
          throw error;
        }
        if (allowError) {
          assert(message.error, `MCP ${method} was expected to fail`);
          await recordDiagnostic({
            outcome: "json-rpc-error",
            httpStatus: response.status,
            errorCode: message.error.code,
            errorCategory: errorCategory(message.error),
          });
          return { error: message.error };
        }
        if (message.error) {
          await recordDiagnostic({
            outcome: "json-rpc-error",
            httpStatus: response.status,
            errorCode: message.error.code,
            errorCategory: errorCategory(message.error),
          });
        } else {
          await recordDiagnostic({
            outcome: "success",
            httpStatus: response.status,
            ...(method === "tools/list" ? { toolCount: message.result?.tools?.length ?? null } : {}),
          });
        }
        assert.equal(message.error, undefined, `MCP ${method} failed: ${JSON.stringify(message.error)}`);
        return message.result;
      };
      await mcp(1, "initialize", { protocolVersion, capabilities: {}, clientInfo: { name: "fixture", version: "1" } });
      const listed = await mcp(2, "tools/list");
      const expectedToolCount = promptText.includes("[fixture:workspace-tool-empty]")
        ? 0
        : Number(process.env.GNOSTIC_ACP_FIXTURE_EXPECTED_WORKSPACE_TOOL_COUNT ?? 1);
      assert.equal(listed.tools.length, expectedToolCount, "tools/list must reflect current Timeline attachments");
      if (listed.tools.length > 0) {
        const requiredToolSuffix = process.env.GNOSTIC_ACP_FIXTURE_WORKSPACE_TOOL_SUFFIX;
        const invocationTool = requiredToolSuffix
          ? listed.tools.find((tool) => tool.name.endsWith(requiredToolSuffix))
          : listed.tools[0];
        assert(invocationTool, `tools/list must include the configured permission tool ${requiredToolSuffix}`);
        const expectsRejection = promptText.includes("[fixture:workspace-tool-rejected]");
        const result = await mcp(
          3,
          "tools/call",
          { name: invocationTool.name, arguments: { query: "fixture" } },
          expectsRejection,
        );
        if (expectsRejection) {
          assert.equal(result.error.code, -32003, "the owner must reject the revoked Workspace invocation");
          sessions.get(params.sessionId).workspaceCallOutcome = `workspace call rejected (${result.error.code})`;
        } else {
          sessions.get(params.sessionId).workspaceCallOutcome = result.content
            ?.map((block) => block.type === "text" ? block.text : "")
            .filter(Boolean)
            .join(" ") ?? "";
        }
      }
    }
    const userMessageId = "fixture-user-1";
    if (promptText.includes("[fixture:unknown-update]")) {
      await client.notify(acp.methods.client.session.update, {
        sessionId: params.sessionId,
        update: {
          sessionUpdate: "vendor_future_update",
          extension: { phase: "fixture" },
          _meta: { trace_id: "fixture-raw-meta" },
        },
      });
    }
    await client.notify(acp.methods.client.session.update, {
      sessionId: params.sessionId,
      update: {
        sessionUpdate: "user_message",
        messageId: userMessageId,
        content: [{ type: "text", text: promptText }],
      },
    });
    await client.notify(acp.methods.client.session.update, {
      sessionId: params.sessionId,
      update: { sessionUpdate: "state_update", state: "running" },
    });
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
        await client.notify(acp.methods.client.session.update, {
          sessionId: params.sessionId,
          update: { sessionUpdate: "state_update", state: "idle", stopReason: "cancelled" },
        });
        return { messageId: userMessageId };
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
        title: "Inspect fixture input",
        subject: {
          type: "tool_call",
          toolCall: {
            toolCallId: "fixture-permission-tool",
            title: "Inspect fixture input",
            kind: "read",
            status: "pending",
          },
        },
        options: process.env.GNOSTIC_ACP_FIXTURE_PERMISSION_CLAUDE === "1"
          ? [
              { optionId: "allow-always", name: "Allow always", kind: "allow_always" },
              { optionId: "allow", name: "Allow", kind: "allow" },
              { optionId: "reject", name: "Reject", kind: "reject" },
            ]
          : process.env.GNOSTIC_ACP_FIXTURE_PERMISSION_UNSUPPORTED === "1"
          ? [
              { optionId: "authorize", name: "Authorize", kind: "authorize" },
              { optionId: "reject-once", name: "Reject once", kind: "reject_once" },
            ]
          : [
              { optionId: "allow-once", name: "Allow once", kind: "allow_once" },
              { optionId: "reject-once", name: "Reject once", kind: "reject_once" },
            ],
      });
      if (process.env.GNOSTIC_ACP_FIXTURE_PERMISSION_RESULT_FILE) {
        await writeFile(process.env.GNOSTIC_ACP_FIXTURE_PERMISSION_RESULT_FILE, JSON.stringify(permission.outcome));
      }
      const outcome = process.env.GNOSTIC_ACP_FIXTURE_PERMISSION_OUTCOME ?? "selected:allow-once";
      if (outcome.startsWith("selected:")) {
        assert.deepEqual(permission.outcome, { outcome: "selected", optionId: outcome.slice("selected:".length) });
      } else {
        assert.deepEqual(permission.outcome, { outcome: "cancelled" });
      }
      if (cancelledSessions.has(params.sessionId)) {
        await client.notify(acp.methods.client.session.update, {
          sessionId: params.sessionId,
          update: { sessionUpdate: "state_update", state: "idle", stopReason: "cancelled" },
        });
        return { messageId: userMessageId };
      }
    }

    const messageId = "fixture-message-1";
    if (prompt.includes("[fixture:agent-message]")) {
      // A whole-message upsert replaces the accumulated text of its message.
      await client.notify(acp.methods.client.session.update, {
        sessionId: params.sessionId,
        update: {
          sessionUpdate: "agent_message",
          messageId,
          content: [{ type: "text", text: `upserted reply: ${prompt}` }],
        },
      });
    } else {
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
          content: {
            type: "text",
            text: `reply: ${prompt}${sessions.get(params.sessionId)?.workspaceCallOutcome ? ` | ${sessions.get(params.sessionId).workspaceCallOutcome}` : ""}`,
          },
        },
      });
    }
    await client.notify(acp.methods.client.session.update, {
      sessionId: params.sessionId,
      update: {
        sessionUpdate: "tool_call_update",
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
    if (process.env.GNOSTIC_ACP_FIXTURE_EXIT_AFTER_PROMPT_MS) {
      setTimeout(() => process.exit(19), Number(process.env.GNOSTIC_ACP_FIXTURE_EXIT_AFTER_PROMPT_MS));
    }
    const idleUpdate = prompt.includes("[fixture:idle-without-stop-reason]")
      ? { sessionUpdate: "state_update", state: "idle" }
      : { sessionUpdate: "state_update", state: "idle", stopReason };
    await client.notify(acp.methods.client.session.update, {
      sessionId: params.sessionId,
      update: idleUpdate,
    });
    return { messageId: userMessageId };
  });

const fixtureOutput = process.env.GNOSTIC_ACP_FIXTURE_ADJACENT_SESSION_UPDATE
  ? new Writable({
      write(chunk, encoding, callback) {
        const message = JSON.parse(chunk.toString().trim());
        if (message.result?.sessionId) {
          const update = {
            jsonrpc: "2.0", method: "session/update",
            params: { sessionId: message.result.sessionId, update: { sessionUpdate: "fixture_session_opened", _meta: { adjacent: true } } },
          };
          const notification = Buffer.from(JSON.stringify(update) + "\n");
          const frames = process.env.GNOSTIC_ACP_FIXTURE_ADJACENT_SESSION_UPDATE === "before"
            ? [notification, Buffer.from(chunk)] : [Buffer.from(chunk), notification];
          process.stdout.write(Buffer.concat(frames), callback);
        } else {
          process.stdout.write(chunk, callback);
        }
      },
    })
  : process.stdout;
const stream = acp.ndJsonStream(
  Writable.toWeb(fixtureOutput),
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
