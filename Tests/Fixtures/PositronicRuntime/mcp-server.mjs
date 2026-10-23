#!/usr/bin/env node

import { createInterface } from "node:readline";

if (process.env.GNOSTIC_PK_API_KEY !== undefined) {
  throw new Error("PositronicKit provider key leaked into the MCP child process");
}
if (process.env.GNOSTIC_GATEWAY_TOKEN !== "runtime-private-token") {
  throw new Error("Configured MCP server environment was not applied");
}

const lines = createInterface({ input: process.stdin });
for await (const line of lines) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    continue;
  }
  if (!Object.hasOwn(message, "id")) continue;
  let result;
  switch (message.method) {
    case "initialize":
      result = {
        protocolVersion: message.params.protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: "positronic-runtime-fixture", version: "1" },
      };
      break;
    case "tools/list":
      result = {
        tools: [{
          name: "fixture_echo",
          description: "Returns the given value.",
          inputSchema: {
            type: "object",
            properties: { value: { type: "string" } },
            required: ["value"],
          },
        }],
      };
      break;
    case "tools/call":
      result = {
        content: [{ type: "text", text: `fixture MCP output: ${message.params.arguments.value}` }],
        isError: false,
      };
      break;
    default:
      process.stdout.write(`${JSON.stringify({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32601, message: `Unsupported method ${message.method}` },
      })}\n`);
      continue;
  }
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result })}\n`);
}
