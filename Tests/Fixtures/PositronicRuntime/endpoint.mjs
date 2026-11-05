#!/usr/bin/env node
// Drives the reference Runtime against a fake provider endpoint and checks how it selects the
// provider and builds the request URL from GNOSTIC_PK_PROVIDER and GNOSTIC_PK_ENDPOINT (#749).
// OpenRouter keeps the endpoint's path prefix. An OpenAI endpoint with a path, which the OpenAI
// client cannot honor, and an unknown provider both fail at startup.

import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";

const binary = process.env.GNOSTIC_PK_RUNTIME_BINARY;
assert(binary, "GNOSTIC_PK_RUNTIME_BINARY is not set");
const stateDir = await mkdtemp(join(tmpdir(), "gnostic-pk-runtime-endpoint-"));
const apiKey = "endpoint-provider-secret";
const reply = "endpoint-reply";

const requests = [];
const endpoint = createServer((request, response) => {
  let body = "";
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    requests.push({ path: request.url, authorization: request.headers.authorization, body: JSON.parse(body || "{}") });
    if (!request.url.endsWith("/v1/chat/completions")) {
      response.writeHead(404, { "content-type": "text/plain" });
      response.end("not found");
      return;
    }
    const chunk = { id: "x", object: "chat.completion.chunk", model: "m", choices: [{ index: 0, delta: { role: "assistant", content: reply }, finish_reason: "stop" }] };
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(`data: ${JSON.stringify(chunk)}\n\ndata: [DONE]\n\n`);
  });
});
await new Promise((resolve) => endpoint.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${endpoint.address().port}`;

function launch(environment) {
  const child = spawn(binary, [], {
    env: { ...process.env, GNOSTIC_PK_STATE_DIR: stateDir, GNOSTIC_PK_API_KEY: apiKey, ...environment },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  const closed = new Promise((resolve) => child.once("close", (status) => resolve(status)));
  return { child, closed, stderr: () => stderr };
}

// Runs one Turn and returns the assistant text.
async function turn(environment, text) {
  const { child, closed, stderr } = launch(environment);
  const messages = [];
  const waiters = [];
  createInterface({ input: child.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    const waiter = waiters.shift();
    if (waiter) waiter(message);
    else messages.push(message);
  });
  const next = () => messages.length
    ? Promise.resolve(messages.shift())
    : Promise.race([
      new Promise((resolve) => waiters.push(resolve)),
      closed.then((status) => { throw new Error(`Runtime exited with ${status}: ${stderr()}`); }),
      new Promise((_, reject) => setTimeout(() => reject(new Error(`Runtime response timeout: ${stderr()}`)), 20_000)),
    ]);
  let nextID = 0;
  const send = (method, params) => {
    const id = ++nextID;
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return id;
  };
  const request = async (method, params) => {
    const id = send(method, params);
    for (;;) {
      const message = await next();
      if (message.id !== id) continue;
      assert(!message.error, JSON.stringify(message.error));
      return message.result;
    }
  };
  try {
    await request("initialize", { protocolVersion: 2, info: { name: "endpoint-test", version: "1" } });
    const { sessionId } = await request("session/new", { cwd: "/tmp/endpoint-project", mcpServers: [] });
    send("session/prompt", { sessionId, prompt: [{ type: "text", text }] });
    let assistant = "";
    for (;;) {
      const message = await next();
      if ("id" in message) {
        assert(!message.error, JSON.stringify(message.error));
        continue;
      }
      const update = message.params.update;
      if (update.sessionUpdate === "agent_message_chunk") assistant += update.content.text;
      if (update.sessionUpdate === "state_update" && update.state === "idle") {
        assert.equal(update.stopReason, "end_turn", `${JSON.stringify(update.stopReason)}: ${stderr()}`);
        return assistant;
      }
    }
  } finally {
    child.stdin.end();
    await closed;
  }
}

// Starts the Runtime and expects it to exit at startup with an error that names `setting`.
async function rejectsAtStartup(environment, setting) {
  const { child, closed, stderr } = launch(environment);
  child.stdin.end();
  const status = await Promise.race([
    closed,
    new Promise((_, reject) => setTimeout(() => reject(new Error("Runtime did not exit at startup")), 10_000)),
  ]);
  assert.notEqual(status, 0, `Runtime started with ${JSON.stringify(environment)}`);
  assert.match(stderr(), new RegExp(setting), `startup error should name ${setting}: ${stderr()}`);
  assert(!stderr().includes(apiKey), "startup error must not print the API key");
}

try {
  // OpenRouter keeps the configured path prefix and sends the key and model.
  const before = requests.length;
  assert.equal(
    await turn({ GNOSTIC_PK_PROVIDER: "openrouter", GNOSTIC_PK_ENDPOINT: `${base}/proxy/api`, GNOSTIC_PK_MODEL: "vendor/endpoint-model" }, "endpoint-prompt"),
    reply,
  );
  const sent = requests.slice(before);
  assert.equal(sent.length, 1, `one provider request, got ${JSON.stringify(sent.map((entry) => entry.path))}`);
  assert.equal(sent[0].path, "/proxy/api/v1/chat/completions");
  assert.equal(sent[0].authorization, `Bearer ${apiKey}`);
  assert.equal(sent[0].body.model, "vendor/endpoint-model");
  assert(JSON.stringify(sent[0].body).includes("endpoint-prompt"), "the prompt reaches the provider");

  // The OpenAI client cannot honor a path, so the Runtime refuses it instead of dropping it.
  await rejectsAtStartup({ GNOSTIC_PK_ENDPOINT: `${base}/prefix` }, "GNOSTIC_PK_ENDPOINT");
  await rejectsAtStartup({ GNOSTIC_PK_PROVIDER: "openai", GNOSTIC_PK_ENDPOINT: `${base}/prefix/v1` }, "GNOSTIC_PK_ENDPOINT");
  // An unknown provider is a configuration error, not a silent fallback to OpenAI.
  await rejectsAtStartup({ GNOSTIC_PK_PROVIDER: "not-a-provider" }, "GNOSTIC_PK_PROVIDER");

  // The default provider still serves an endpoint without a path, as before.
  assert.equal(await turn({ GNOSTIC_PK_ENDPOINT: base, GNOSTIC_PK_MODEL: "endpoint-default-model" }, "endpoint-default"), reply);
  assert.equal(requests.at(-1).path, "/v1/chat/completions");
  // A trailing /v1, the usual way to write an OpenAI-compatible endpoint, keeps working.
  assert.equal(await turn({ GNOSTIC_PK_ENDPOINT: `${base}/v1/`, GNOSTIC_PK_MODEL: "endpoint-v1-model" }, "endpoint-v1"), reply);
  assert.equal(requests.at(-1).path, "/v1/chat/completions");
  process.stdout.write("Positronic Runtime endpoint passed\n");
} finally {
  endpoint.close();
  await rm(stateDir, { recursive: true, force: true });
}
