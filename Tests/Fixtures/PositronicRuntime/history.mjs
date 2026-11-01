#!/usr/bin/env node
// Drives the reference Runtime through Turn, restart, Turn, restart, Turn against a fake
// OpenAI endpoint. Asserts that the session file keeps every Turn and that each provider
// request carries earlier conversation exactly once (#682).

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";

const binary = process.env.GNOSTIC_PK_RUNTIME_BINARY;
assert(binary, "GNOSTIC_PK_RUNTIME_BINARY is not set");
const stateDir = await mkdtemp(join(tmpdir(), "gnostic-pk-runtime-history-"));
const cwd = "/tmp/history-project";
const prompts = ["history-user-alpha", "history-user-bravo", "history-user-charlie", "history-user-delta"];
const replies = ["history-reply-one", "history-reply-two", "history-reply-three", "history-reply-four"];

const requests = [];
const endpoint = createServer((request, response) => {
  let body = "";
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    const index = requests.length;
    requests.push({ path: request.url, body: JSON.parse(body || "{}"), bytes: Buffer.byteLength(body) });
    const text = replies[index] ?? "history-reply-extra";
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (request.url.includes("chat/completions")) {
      const chunk = { id: "x", object: "chat.completion.chunk", model: "m", choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: "stop" }] };
      response.end(`data: ${JSON.stringify(chunk)}\n\ndata: [DONE]\n\n`);
    } else {
      const completed = { id: "r", object: "response", model: "m", status: "completed", output: [{ type: "message", id: "o", role: "assistant", status: "completed", content: [{ type: "output_text", text }] }], usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } };
      const delta = { type: "response.output_text.delta", delta: text, output_index: 0, content_index: 0, item_id: "o" };
      response.end(`event: response.output_text.delta\ndata: ${JSON.stringify(delta)}\n\nevent: response.completed\ndata: ${JSON.stringify({ type: "response.completed", response: completed })}\n\n`);
    }
  });
});
await new Promise((resolve) => endpoint.listen(0, "127.0.0.1", resolve));

function launch() {
  const child = spawn(binary, [], {
    env: {
      ...process.env,
      GNOSTIC_PK_STATE_DIR: stateDir,
      GNOSTIC_PK_API_KEY: "runtime-provider-secret",
      GNOSTIC_PK_MODEL: "history-model",
      GNOSTIC_PK_ENDPOINT: `http://127.0.0.1:${endpoint.address().port}`,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const messages = [];
  const waiters = [];
  let stderr = "";
  let nextID = 0;
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
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
      new Promise((_, reject) => setTimeout(() => reject(new Error(`Runtime response timeout: ${stderr}`)), 20_000)),
    ]);
  return {
    async request(method, params) {
      const id = ++nextID;
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      for (;;) {
        const message = await next();
        if (message.id !== id) continue;
        assert(!message.error, JSON.stringify(message.error));
        return message.result;
      }
    },
    async turn(sessionId, text) {
      const id = ++nextID;
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method: "session/prompt", params: { sessionId, prompt: [{ type: "text", text }] } })}\n`);
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
          assert.equal(update.stopReason, "end_turn", JSON.stringify(update.stopReason));
          return assistant;
        }
      }
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

async function start() {
  const client = launch();
  await client.request("initialize", { protocolVersion: 2, info: { name: "history-test", version: "1" } });
  return client;
}

const occurrences = (haystack, needle) => haystack.split(needle).length - 1;
const savedTranscript = async () => JSON.parse(await readFile(join(stateDir, "sessions.json"), "utf8")).sessions[0].transcript;

try {
  let client = await start();
  const { sessionId } = await client.request("session/new", { cwd, mcpServers: [] });
  assert.equal(await client.turn(sessionId, prompts[0]), replies[0]);
  await client.stop();

  client = await start();
  await client.request("session/resume", { sessionId, cwd, mcpServers: [] });
  assert.equal(await client.turn(sessionId, prompts[1]), replies[1]);
  await client.stop();

  client = await start();
  await client.request("session/resume", { sessionId, cwd, mcpServers: [] });
  assert.equal(await client.turn(sessionId, prompts[2]), replies[2]);
  // A further Turn in the same process must not add a second copy of the history either.
  assert.equal(await client.turn(sessionId, prompts[3]), replies[3]);

  assert.equal(requests.length, 4, "one provider request per Turn");
  const bodies = requests.map((request) => JSON.stringify(request.body));
  // Every request carries each earlier message exactly once and the current prompt once.
  for (const [turn, body] of bodies.entries()) {
    for (let index = 0; index < prompts.length; index += 1) {
      for (const [token, expected] of [[prompts[index], index <= turn ? 1 : 0], [replies[index], index < turn ? 1 : 0]]) {
        assert.equal(
          occurrences(body, token),
          expected,
          `Turn ${turn + 1} request holds "${token}" ${occurrences(body, token)} times, expected ${expected}`,
        );
      }
    }
  }
  // Request size grows by about one exchange per Turn, not by a second copy of the history.
  const growth = requests.slice(1).map((request, index) => request.bytes - requests[index].bytes);
  assert(growth.at(-1) < growth[0] * 1.5, `request growth ${growth.join(", ")} bytes is not linear`);

  const transcript = await savedTranscript();
  assert.deepEqual(
    transcript.map((message) => [message.role, message.content]),
    [
      ["user", prompts[0]], ["assistant", replies[0]],
      ["user", prompts[1]], ["assistant", replies[1]],
      ["user", prompts[2]], ["assistant", replies[2]],
      ["user", prompts[3]], ["assistant", replies[3]],
    ],
    "the session file must hold every Turn after two restarts",
  );

  await client.request("session/close", { sessionId });
  await client.stop();

  // A session file written before messages carried ids and timestamps still resumes, once.
  await rm(join(stateDir, "sessions.json"));
  const legacyID = "legacy-session";
  await writeFile(join(stateDir, "sessions.json"), JSON.stringify({
    formatVersion: 1,
    sessions: [{
      id: legacyID,
      cwd,
      title: "ACP Session",
      updatedAt: "2026-01-01T00:00:00Z",
      transcript: [
        { role: "user", content: "legacy-user-one" },
        { role: "assistant", content: "legacy-reply-one" },
      ],
    }],
  }));
  const before = requests.length;
  client = await start();
  await client.request("session/resume", { sessionId: legacyID, cwd, mcpServers: [] });
  await client.turn(legacyID, "legacy-user-two");
  const legacyBody = JSON.stringify(requests[before].body);
  for (const token of ["legacy-user-one", "legacy-reply-one", "legacy-user-two"]) {
    assert.equal(occurrences(legacyBody, token), 1, `legacy request holds "${token}" ${occurrences(legacyBody, token)} times`);
  }
  assert(legacyBody.indexOf("legacy-user-one") < legacyBody.indexOf("legacy-reply-one"), "legacy order");
  assert(legacyBody.indexOf("legacy-reply-one") < legacyBody.indexOf("legacy-user-two"), "legacy order");
  await client.stop();
  process.stdout.write(`Positronic Runtime history passed: request bytes ${requests.map((request) => request.bytes).join(", ")}\n`);
} finally {
  endpoint.close();
  await rm(stateDir, { recursive: true, force: true });
}
