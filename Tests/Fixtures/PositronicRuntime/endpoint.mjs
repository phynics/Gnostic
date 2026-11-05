#!/usr/bin/env node
// Drives the reference Runtime against a fake provider endpoint and checks how it selects the
// provider and builds the request URL from GNOSTIC_PK_PROVIDER and GNOSTIC_PK_ENDPOINT (#749).
// A trailing /v1 is the base for both providers. OpenRouter keeps the rest of the path. An OpenAI
// endpoint with another path, an endpoint with a query or credentials, a non-URL endpoint, and
// an unknown provider all fail at startup.

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

// The caller's own Runtime settings must not leak into a case.
const inherited = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GNOSTIC_PK_")));
const timeout = (milliseconds, message) => new Promise((_, reject) => {
  setTimeout(() => reject(new Error(message())), milliseconds).unref();
});

function launch(environment) {
  const child = spawn(binary, [], {
    env: { ...inherited, GNOSTIC_PK_STATE_DIR: stateDir, GNOSTIC_PK_API_KEY: apiKey, ...environment },
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
      timeout(20_000, () => `Runtime response timeout: ${stderr()}`),
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
async function rejectsAtStartup(environment, setting, secret) {
  const { child, closed, stderr } = launch(environment);
  child.stdin.end();
  const status = await Promise.race([
    closed,
    timeout(10_000, () => "Runtime did not exit at startup"),
  ]);
  assert.notEqual(status, 0, `Runtime started with ${JSON.stringify(environment)}`);
  assert.match(stderr(), new RegExp(setting), `startup error should name ${setting}: ${stderr()}`);
  assert(!stderr().includes(apiKey), "startup error must not print the API key");
  if (secret) assert(!stderr().includes(secret), "startup error must not echo the configured value");
}

// Runs one Turn and returns the path of the single provider request it made.
async function requestPath(environment, prompt) {
  const before = requests.length;
  assert.equal(await turn(environment, prompt), reply);
  const sent = requests.slice(before);
  assert.equal(sent.length, 1, `one provider request, got ${JSON.stringify(sent.map((entry) => entry.path))}`);
  return sent[0].path;
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

  // OpenRouter's documented base URL ends in /api/v1; it must not become /api/v1/api/v1.
  const openRouter = { GNOSTIC_PK_PROVIDER: "openrouter", GNOSTIC_PK_MODEL: "vendor/endpoint-model" };
  assert.equal(await requestPath({ ...openRouter, GNOSTIC_PK_ENDPOINT: `${base}/proxy/api/v1` }, "or-v1"), "/proxy/api/v1/chat/completions");
  // PositronicKit adds /api unless the path already ends in it.
  assert.equal(await requestPath({ ...openRouter, GNOSTIC_PK_ENDPOINT: `${base}/gateway/` }, "or-gateway"), "/gateway/api/v1/chat/completions");
  // Provider names and URL schemes are case-insensitive.
  assert.equal(
    await requestPath({ ...openRouter, GNOSTIC_PK_PROVIDER: "OpenRouter", GNOSTIC_PK_ENDPOINT: `HTTP://127.0.0.1:${endpoint.address().port}/proxy/api` }, "or-case"),
    "/proxy/api/v1/chat/completions",
  );

  // The OpenAI client cannot honor a path other than /v1, so the Runtime refuses it instead of
  // dropping it.
  await rejectsAtStartup({ GNOSTIC_PK_ENDPOINT: `${base}/prefix` }, "GNOSTIC_PK_ENDPOINT");
  await rejectsAtStartup({ GNOSTIC_PK_PROVIDER: "openai", GNOSTIC_PK_ENDPOINT: `${base}/prefix/v1` }, "GNOSTIC_PK_ENDPOINT");
  // Neither client sends a query or URL credentials, and the error must not echo them.
  await rejectsAtStartup({ GNOSTIC_PK_ENDPOINT: `${base}/?api-version=1` }, "GNOSTIC_PK_ENDPOINT");
  await rejectsAtStartup(
    { ...openRouter, GNOSTIC_PK_ENDPOINT: `http://user:url-secret@127.0.0.1:${endpoint.address().port}/api` },
    "GNOSTIC_PK_ENDPOINT",
    "url-secret",
  );
  await rejectsAtStartup({ GNOSTIC_PK_ENDPOINT: "not-a-url" }, "GNOSTIC_PK_ENDPOINT");
  // An unknown provider is a configuration error, not a silent fallback to OpenAI.
  await rejectsAtStartup({ GNOSTIC_PK_PROVIDER: "provider-secret-typo" }, "GNOSTIC_PK_PROVIDER", "provider-secret-typo");

  // The default provider still serves an endpoint without a path, as before, and the usual
  // trailing /v1, with or without a slash.
  assert.equal(await requestPath({ GNOSTIC_PK_ENDPOINT: base }, "default-root"), "/v1/chat/completions");
  assert.equal(await requestPath({ GNOSTIC_PK_ENDPOINT: `${base}/v1` }, "default-v1"), "/v1/chat/completions");
  assert.equal(await requestPath({ GNOSTIC_PK_ENDPOINT: `${base}/v1/` }, "default-v1-slash"), "/v1/chat/completions");
  process.stdout.write("Positronic Runtime endpoint passed\n");
} finally {
  endpoint.close();
  await rm(stateDir, { recursive: true, force: true });
}
