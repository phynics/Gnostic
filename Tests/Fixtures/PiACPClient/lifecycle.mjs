import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk/experimental/v2";
import { loadConfig } from "@phynics/pi-acp-client/config.ts";

const binary = process.env.GNOSTIC_ACP_BINARY;
const sourceArgs = JSON.parse(process.env.GNOSTIC_ACP_PROFILE_SOURCE_ARGS ?? "[]");
const timelineFile = process.env.GNOSTIC_PI_ACP_TIMELINE_FILE;
const attachedFile = process.env.GNOSTIC_PI_ACP_ATTACHED_FILE;
if (!binary || !Array.isArray(sourceArgs) || !timelineFile || !attachedFile) {
  throw new Error("missing Gnostic ACP fixture configuration");
}

const state = await mkdtemp(join(tmpdir(), "gnostic-pi-acp-client-"));
const configPath = join(state, "profiles.json");
const cwd = join(state, "workspace");
let child;
try {
  await mkdir(cwd);
  await writeFile(configPath, JSON.stringify({
    version: 1,
    profiles: [],
    sources: [{ command: binary, args: sourceArgs }],
  }));
  process.env.PI_ACP_CONFIG = configPath;
  process.env.PATH = `${dirname(binary)}:${process.env.PATH ?? ""}`;

  const config = await loadConfig(cwd);
  if (config.profiles.length !== 1) throw new Error(`expected one discovered profile, got ${config.profiles.length}`);
  const profile = config.profiles[0];
  if (profile.command !== "gnostic" || !profile.args?.includes("--ascendant")) {
    throw new Error("Gnostic source did not emit an immutable Ascendant profile");
  }

  child = spawn(profile.command, profile.args ?? [], {
    cwd,
    env: { ...process.env, ...(profile.env ?? {}) },
    stdio: ["pipe", "pipe", "inherit"],
  });
  const stream = acp.ndJsonStream(
    Writable.toWeb(child.stdin),
    Readable.toWeb(child.stdout),
  );
  const notifications = [];
  let permissionRequested = false;
  await acp.client({ name: "gnostic-pi-acp-client-fixture" })
    .onNotification(acp.methods.client.session.update, ({ params }) => {
      notifications.push(params);
    })
    .onRequest(acp.methods.client.session.requestPermission, async () => {
      permissionRequested = true;
      return { outcome: { outcome: "selected", optionId: "allow_once" } };
    })
    .connectWith(stream, async (ctx) => {
      const initialized = await ctx.request(acp.methods.agent.initialize, {
        protocolVersion: acp.PROTOCOL_VERSION,
        capabilities: {},
        info: { name: "gnostic-pi-acp-client-fixture", version: "1" },
      });
      if (initialized.protocolVersion !== acp.PROTOCOL_VERSION) {
        throw new Error("Gnostic negotiated an unsupported ACP version");
      }
      if (!initialized.capabilities?.session) {
        throw new Error("Gnostic did not advertise stable session capabilities");
      }
      const created = await ctx.request(acp.methods.agent.session.new, { cwd, mcpServers: [] });
      if (typeof created.sessionId !== "string") throw new Error("Gnostic did not create an ACP session");
      const timelineID = created?._meta?.gnosticTimelineID;
      if (typeof timelineID !== "string") throw new Error("Gnostic did not identify the Timeline for the fixture");
      await mkdir(dirname(timelineFile), { recursive: true });
      await writeFile(timelineFile, `${timelineID}\n`);
      await waitForFile(attachedFile);

      const promptStart = notifications.length;
      const accepted = await ctx.request(acp.methods.agent.session.prompt, {
        sessionId: created.sessionId,
        prompt: [{ type: "text", text: "use the attached workspace" }],
        _meta: { "dev.phynics.pi-acp-client/clientTurnID": "pi-acp-client-smoke:turn-1" },
      });
      if (typeof accepted.messageId !== "string") throw new Error("Gnostic did not acknowledge the user message");
      await waitForIdle(notifications, promptStart);
      const updates = JSON.stringify(notifications);
      if (!permissionRequested || !updates.includes("workspace_echo") || !updates.includes("Echo received: network")) {
        throw new Error(`Pi ACP client did not complete the permissioned Workspace tool turn: ${updates}`);
      }
      process.stdout.write("pi-acp-client Workspace tool turn passed\n");
      const listed = await ctx.request(acp.methods.agent.session.list, { cwd });
      if (!listed.sessions.some((session) => session.sessionId === created.sessionId)) {
        throw new Error("Gnostic did not list the created ACP session");
      }
      await ctx.request(acp.methods.agent.session.close, { sessionId: created.sessionId });
      await ctx.request(acp.methods.agent.session.resume, { sessionId: created.sessionId, cwd, mcpServers: [] });
      await ctx.request(acp.methods.agent.session.close, { sessionId: created.sessionId });
    });
  process.stdout.write("pi-acp-client Gnostic lifecycle passed\n");
} finally {
  child?.kill();
  await rm(state, { recursive: true, force: true });
}

async function waitForIdle(updates, start) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const idle = updates.slice(start).find((params) =>
      params.update?.sessionUpdate === "state_update"
        && params.update.state === "idle"
        && params.update.stopReason === "end_turn"
    );
    if (idle) return idle;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`timed out waiting for idle: ${JSON.stringify(updates.slice(start))}`);
}

async function waitForFile(path) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      await readFile(path);
      return;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timed out waiting for ${path}`);
}
