// A minimal Letta REST + SSE fixture server for the Gnostic Letta transport
// test. It has no dependencies and no credential; it binds an ephemeral port on
// 127.0.0.1 and prints the chosen port on stdout.
//
// Endpoints mirror the documented Letta API surface the backend uses:
//   GET    /v1/health/
//   GET    /v1/agents/
//   POST   /v1/agents
//   PATCH  /v1/agents/{id}
//   GET    /v1/conversations/
//   POST   /v1/conversations/
//   PATCH  /v1/conversations/{id}
//   DELETE /v1/conversations/{id}
//   POST   /v1/conversations/{id}/cancel
//   POST   /v1/conversations/{id}/messages   (Server-Sent Events)

import http from "node:http";
import { randomUUID } from "node:crypto";

const args = process.argv.slice(2);
const portIndex = args.indexOf("--port");
const requestedPort = portIndex >= 0 ? Number(args[portIndex + 1]) : 0;

const sendJSON = (res, status, value) => {
  const text = JSON.stringify(value);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(text),
  });
  res.end(text);
};

const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => {
    body += chunk;
  });
  req.on("end", () => {
    const url = new URL(req.url, "http://127.0.0.1");
    const path = url.pathname;

    if (req.method === "GET" && path === "/v1/health/") {
      return sendJSON(res, 200, { status: "ok", version: "fixture" });
    }
    if (req.method === "GET" && path === "/v1/agents/") {
      return sendJSON(res, 200, []);
    }
    if (req.method === "POST" && path === "/v1/agents") {
      return sendJSON(res, 200, { id: `agent-${randomUUID()}`, name: "Fixture", metadata: {} });
    }
    if (req.method === "PATCH" && path.startsWith("/v1/agents/")) {
      return sendJSON(res, 200, {});
    }
    if (req.method === "GET" && path === "/v1/conversations/") {
      return sendJSON(res, 200, []);
    }
    if (req.method === "POST" && path === "/v1/conversations/") {
      return sendJSON(res, 200, {
        id: `conv-${randomUUID()}`,
        agent_id: url.searchParams.get("agent_id") ?? "",
        description: "",
      });
    }
    if (req.method === "PATCH" && path.startsWith("/v1/conversations/")) {
      return sendJSON(res, 200, {});
    }
    if (req.method === "DELETE" && path.startsWith("/v1/conversations/")) {
      return sendJSON(res, 200, {});
    }
    if (req.method === "POST" && path.endsWith("/cancel")) {
      return sendJSON(res, 200, {});
    }
    if (req.method === "POST" && path.endsWith("/messages")) {
      const events = [
        { message_type: "assistant_message", content: "http-reply" },
        { stop_reason: "end_turn" },
      ];
      const text = events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Content-Length": Buffer.byteLength(text),
      });
      res.end(text);
      return;
    }
    sendJSON(res, 404, { error: "not_found", path, method: req.method });
  });
});

server.listen(requestedPort, "127.0.0.1", () => {
  process.stdout.write(`${server.address().port}\n`);
});
