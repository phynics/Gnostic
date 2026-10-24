#!/usr/bin/env node

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";

const binary = process.env.GNOSTIC_PK_RUNTIME_BINARY;
assert(binary, "GNOSTIC_PK_RUNTIME_BINARY is not set");
const stateDir = await mkdtemp(join(tmpdir(), "gnostic-pk-runtime-lifecycle-"));
const gatewayFailures = [];
const gatewayCalls = [];
const httpGateway = createServer(async (request, response) => {
  try {
    assert.equal(request.method, "POST");
    assert.equal(request.url, "/mcp");
    assert.equal(request.headers.authorization, "Bearer fixture-http-token");
    assert.equal(request.headers["content-type"], "application/json");
    assert(request.headers.accept.includes("application/json"));
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const message = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (message.method === "initialize") {
      assert.equal(request.headers["mcp-protocol-version"], undefined);
      const protocolVersion = message.params.protocolVersion;
      assert.equal(protocolVersion, "2025-03-26");
      response.writeHead(200, { "content-type": "application/json", "mcp-protocol-version": protocolVersion });
      response.end(JSON.stringify({
        jsonrpc: "2.0",
        id: message.id,
        result: { protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "http-fixture", version: "1" } },
      }));
      return;
    }
    assert.equal(request.headers["mcp-protocol-version"], "2025-03-26");
    if (message.method === "notifications/initialized") {
      response.writeHead(202, { "content-length": "0" });
      response.end();
      return;
    }
    let result;
    if (message.method === "tools/list") {
      result = { tools: [{ name: "http_echo", description: "Echo over HTTP", inputSchema: { type: "object", properties: { value: { type: "string" } } } }] };
    } else if (message.method === "tools/call") {
      gatewayCalls.push(message.params);
      result = { content: [{ type: "text", text: `fixture HTTP MCP output: ${message.params.arguments.value}` }], isError: false };
    } else {
      throw new Error(`Unexpected MCP method ${message.method}`);
    }
    response.writeHead(200, { "content-type": "application/json", "mcp-protocol-version": "2025-03-26" });
    response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
  } catch (error) {
    gatewayFailures.push(String(error));
    response.writeHead(500, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: String(error) }));
  }
});
await new Promise((resolve, reject) => {
  httpGateway.once("error", reject);
  httpGateway.listen(0, "127.0.0.1", resolve);
});
const httpAddress = httpGateway.address();
assert(httpAddress && typeof httpAddress === "object");
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
const pending = [];
const waiters = [];
let stderr = "";
child.stderr.setEncoding("utf8").on("data", (text) => { stderr += text; });
lines.on("line", (line) => {
  const waiter = waiters.shift();
  if (waiter) waiter(JSON.parse(line));
  else pending.push(JSON.parse(line));
});

function nextMessage(timeoutMs = 20_000) {
  if (pending.length) return Promise.resolve(pending.shift());
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      const index = waiters.indexOf(onMessage);
      if (index >= 0) waiters.splice(index, 1);
      reject(new Error(`Timed out waiting for Runtime output. stderr=${stderr}`));
    }, timeoutMs);
    function onMessage(message) {
      clearTimeout(timeout);
      resolve(message);
    }
    waiters.push(onMessage);
  });
}

function send(method, id, params) {
  const line = `${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`;
  child.stdin.write(line);
}

function notify(method, params) {
  const line = `${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`;
  child.stdin.write(line);
}

try {
  send("initialize", 1, { protocolVersion: 2, info: { name: "test", version: "1" } });
  const initialized = await nextMessage();
  assert.equal(initialized.id, 1);
  assert.equal(initialized.result.protocolVersion, 2);

  send("session/new", 2, {
    cwd: "/tmp",
    mcpServers: [{
      type: "stdio",
      name: "fixture-gateway",
      command: process.execPath,
      args: [`${process.cwd()}/Tests/Fixtures/PositronicRuntime/mcp-server.mjs`],
      env: [{ name: "GNOSTIC_GATEWAY_TOKEN", value: "runtime-private-token" }],
    }, {
      type: "http",
      name: "fixture-http-gateway",
      url: `http://127.0.0.1:${httpAddress.port}/mcp`,
      headers: [{ name: "Authorization", value: "Bearer fixture-http-token" }],
    }],
  });
  const created = await nextMessage();
  const sessionId = created.result.sessionId;
  const stateDirectoryStat = await stat(stateDir);
  const stateFileStat = await stat(join(stateDir, "sessions.json"));
  const persistedState = await readFile(join(stateDir, "sessions.json"), "utf8");
  assert.equal(stateDirectoryStat.mode & 0o777, 0o700);
  assert.equal(stateFileStat.mode & 0o777, 0o600);
  assert(!persistedState.includes("runtime-private-token"), "MCP credentials must not enter session persistence");
  assert(!persistedState.includes("runtime-provider-secret"), "provider credentials must not enter session persistence");

  for (const [id, prompt] of [[3, "first"], [4, "second"]]) {
    send("session/prompt", id, {
      sessionId,
      prompt: [{ type: "text", text: prompt }],
    });
    let responseSeen = false;
    let userSeen = false;
    let assistantText = "";
    let idleSeen = false;
    while (!idleSeen) {
      const message = await nextMessage();
      if ("id" in message) {
        assert.equal(message.id, id);
        assert(!message.error, JSON.stringify(message.error));
        responseSeen = true;
        continue;
      }
      assert.equal(message.method, "session/update");
      const update = message.params.update;
      if (update.sessionUpdate === "user_message") userSeen = true;
      if (update.sessionUpdate === "agent_message_chunk") assistantText += update.content.text;
      if (update.sessionUpdate === "state_update" && update.state === "idle") idleSeen = true;
    }
    assert(responseSeen && userSeen && assistantText.includes(prompt),
      JSON.stringify({ responseSeen, userSeen, assistantText }));
  }

  send("session/prompt", 5, {
    sessionId,
    prompt: [{ type: "text", text: "[fixture:tool] use the MCP tool" }],
  });
  let toolResponseSeen = false;
  let toolText = "";
  let toolIdle = false;
  while (!toolIdle) {
    const message = await nextMessage();
    if ("id" in message) {
      assert.equal(message.id, 5);
      assert(!message.error, JSON.stringify(message.error));
      toolResponseSeen = true;
      continue;
    }
    const update = message.params.update;
    if (update.sessionUpdate === "agent_message_chunk") toolText += update.content.text;
    if (update.sessionUpdate === "state_update" && update.state === "idle") toolIdle = true;
  }
  assert(toolResponseSeen && toolText.includes("fixture MCP output: hello"), toolText);

  send("session/prompt", 6, {
    sessionId,
    prompt: [{ type: "text", text: "[fixture:http-tool] use the HTTP MCP tool" }],
  });
  let httpResponseSeen = false;
  let httpToolText = "";
  let httpToolIdle = false;
  while (!httpToolIdle) {
    const message = await nextMessage();
    if ("id" in message) {
      assert.equal(message.id, 6);
      assert(!message.error, JSON.stringify(message.error));
      httpResponseSeen = true;
      continue;
    }
    const update = message.params.update;
    if (update.sessionUpdate === "agent_message_chunk") httpToolText += update.content.text;
    if (update.sessionUpdate === "state_update" && update.state === "idle") httpToolIdle = true;
  }
  assert(httpResponseSeen && httpToolText.includes("fixture HTTP MCP output: hello"), httpToolText);
  assert.equal(gatewayCalls.length, 1);
  assert.deepEqual(gatewayCalls[0], { name: "http_echo", arguments: { value: "hello" } });
  assert.deepEqual(gatewayFailures, []);

  send("session/prompt", 7, {
    sessionId,
    prompt: [{ type: "text", text: "[fixture:wait] cancel" }],
  });
  let cancelAcknowledged = false;
  let cancelSent = false;
  let cancelledIdle = false;
  while (!cancelledIdle) {
    const message = await nextMessage();
    if ("id" in message) {
      assert.equal(message.id, 7);
      assert(!message.error, JSON.stringify(message.error));
      cancelAcknowledged = true;
      continue;
    }
    assert.equal(message.method, "session/update");
    const update = message.params.update;
    if (update.sessionUpdate === "state_update" && update.state === "running" && !cancelSent) {
      notify("session/cancel", { sessionId });
      cancelSent = true;
    }
    if (update.sessionUpdate === "state_update" && update.state === "idle") {
      cancelledIdle = update.stopReason === "cancelled";
    }
  }
  assert(cancelAcknowledged && cancelSent && cancelledIdle,
    JSON.stringify({ cancelAcknowledged, cancelSent, cancelledIdle }));

  send("session/close", 8, { sessionId });
  const closed = await nextMessage();
  assert.equal(closed.id, 8);
  assert(!closed.error, JSON.stringify(closed.error));
  child.stdin.end();
  const [status] = await new Promise((resolve) => child.on("close", (...values) => resolve(values)));
  assert.equal(status, 0, stderr);
  process.stdout.write("scripted Positronic Runtime ACP lifecycle passed\n");
} catch (error) {
  child.kill("SIGTERM");
  process.stderr.write(`${error.stack ?? error}\n${stderr}`);
  process.exitCode = 1;
} finally {
  httpGateway.closeAllConnections();
  await new Promise((resolve) => httpGateway.close(resolve));
  await rm(stateDir, { recursive: true, force: true });
}
