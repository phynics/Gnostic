#!/usr/bin/env node

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";

const binary = process.env.GNOSTIC_PK_RUNTIME_BINARY;
assert(binary, "GNOSTIC_PK_RUNTIME_BINARY is not set");
const stateDir = await mkdtemp(join(tmpdir(), "gnostic-pk-runtime-state-"));
const mcpServer = {
  type: "stdio",
  name: "fixture-gateway",
  command: process.execPath,
  args: [`${process.cwd()}/Tests/Fixtures/PositronicRuntime/mcp-server.mjs`],
  env: [{ name: "GNOSTIC_GATEWAY_TOKEN", value: "runtime-private-token" }],
};

function launch() {
  const child = spawn(binary, [], {
    env: {
      ...process.env,
      GNOSTIC_PK_SCRIPTED: "1",
      GNOSTIC_PK_STATE_DIR: stateDir,
      GNOSTIC_PK_API_KEY: "runtime-provider-secret",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const lines = createInterface({ input: child.stdout });
  const messages = [];
  const waiters = [];
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  lines.on("line", (line) => {
    const message = JSON.parse(line);
    const waiter = waiters.shift();
    if (waiter) waiter(message);
    else messages.push(message);
  });
  return {
    child,
    send(method, id, params) {
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    },
    async next() {
      if (messages.length) return messages.shift();
      return Promise.race([
        new Promise((resolve) => waiters.push(resolve)),
        new Promise((_, reject) => setTimeout(() => reject(new Error(`Runtime response timeout: ${stderr}`)), 20_000)),
      ]);
    },
    async stop() {
      child.stdin.end();
      const [status] = await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error(`Runtime did not stop: ${stderr}`)), 10_000);
        child.once("close", (...args) => { clearTimeout(timeout); resolve(args); });
      });
      assert.equal(status, 0, stderr);
    },
  };
}

async function initialize(client, id = 1) {
  client.send("initialize", id, { protocolVersion: 2, info: { name: "persistence-test", version: "1" } });
  const response = await client.next();
  assert.equal(response.id, id);
  assert.equal(response.result.protocolVersion, 2);
}

try {
  const first = launch();
  await initialize(first);
  first.send("session/new", 2, { cwd: "/tmp/persistent-project", mcpServers: [mcpServer] });
  const created = await first.next();
  const sessionId = created.result.sessionId;
  first.send("session/prompt", 3, {
    sessionId,
    prompt: [{ type: "text", text: "[fixture:tool] persist this conversation" }],
  });
  let firstIdle = false;
  while (!firstIdle) {
    const message = await first.next();
    if ("id" in message) {
      assert.equal(message.id, 3);
      assert(!message.error, JSON.stringify(message.error));
    } else if (message.params.update.sessionUpdate === "state_update" && message.params.update.state === "idle") {
      firstIdle = true;
    }
  }
  const savedState = await readFile(join(stateDir, "sessions.json"), "utf8");
  assert(!savedState.includes("runtime-private-token"));
  assert(!savedState.includes("runtime-provider-secret"));
  assert(savedState.includes("fixture MCP output: hello"), "tool result must be included in persisted transcript");
  await first.stop();

  const second = launch();
  await initialize(second);
  second.send("session/list", 2, { cwd: "/tmp/persistent-project" });
  const listed = await second.next();
  assert.equal(listed.result.sessions.length, 1);
  assert.equal(listed.result.sessions[0].sessionId, sessionId);

  second.send("session/resume", 3, { sessionId, cwd: "/tmp/persistent-project", mcpServers: [mcpServer] });
  const resumed = await second.next();
  assert.equal(resumed.id, 3);
  assert(!resumed.error, JSON.stringify(resumed.error));

  second.send("session/prompt", 4, {
    sessionId,
    prompt: [{ type: "text", text: "[fixture:tool-after-resume] continue after restart" }],
  });
  let assistant = "";
  let secondIdle = false;
  while (!secondIdle) {
    const message = await second.next();
    if ("id" in message) {
      assert.equal(message.id, 4);
      assert(!message.error, JSON.stringify(message.error));
    } else {
      const update = message.params.update;
      if (update.sessionUpdate === "agent_message_chunk") assistant += update.content.text;
      if (update.sessionUpdate === "state_update" && update.state === "idle") secondIdle = true;
    }
  }
  assert(assistant.includes("fixture MCP output: hello") && assistant.includes("prior MCP tool context restored"), assistant);
  second.send("session/close", 5, { sessionId });
  const closed = await second.next();
  assert.equal(closed.id, 5);
  assert(!closed.error, JSON.stringify(closed.error));
  await second.stop();
  process.stdout.write("scripted Positronic Runtime session persistence passed\n");
} finally {
  await rm(stateDir, { recursive: true, force: true });
}
