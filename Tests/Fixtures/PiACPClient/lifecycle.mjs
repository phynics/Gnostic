import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ACPClient } from "@phynics/pi-acp-client/acp.ts";
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

  const notifications = [];
  let permissionRequested = false;
  const client = new ACPClient({
    profile,
    cwd,
    onNotification: (notification) => notifications.push(notification),
    onPermission: async () => {
      permissionRequested = true;
      return { outcome: { outcome: "selected", optionId: "allow_once" } };
    },
  });
  await client.start();
  if (!client.supportsSessionList) throw new Error("Gnostic did not advertise stable session/list");
  const created = await client.newSession(cwd);
  if (typeof created.sessionId !== "string") throw new Error("Gnostic did not create an ACP session");
  const timelineID = created?._meta?.gnosticTimelineID;
  if (typeof timelineID !== "string") throw new Error("Gnostic did not identify the Timeline for the fixture");
  await mkdir(dirname(timelineFile), { recursive: true });
  await writeFile(timelineFile, `${timelineID}\n`);
  await waitForFile(attachedFile);
  await client.prompt(created.sessionId, "use the attached workspace", {
    "dev.phynics.pi-acp-client/clientTurnID": "pi-acp-client-smoke:turn-1",
  });
  const updates = JSON.stringify(notifications);
  if (!permissionRequested || !updates.includes("workspace_echo") || !updates.includes("Echo received: network")) {
    throw new Error(`Pi ACP client did not complete the permissioned Workspace tool turn: ${updates}`);
  }
  process.stdout.write("pi-acp-client Workspace tool turn passed\n");
  const listed = await client.list(cwd);
  if (!listed.some((session) => session.sessionId === created.sessionId)) {
    throw new Error("Gnostic did not list the created ACP session");
  }
  await client.closeSession(created.sessionId);
  await client.resume(created.sessionId, cwd);
  await client.shutdown();
  process.stdout.write("pi-acp-client Gnostic lifecycle passed\n");
} finally {
  await rm(state, { recursive: true, force: true });
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
