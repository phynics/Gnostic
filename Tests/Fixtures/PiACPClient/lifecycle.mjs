import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ACPClient } from "@phynics/pi-acp-client/acp.ts";
import { loadConfig } from "@phynics/pi-acp-client/config.ts";

const binary = process.env.GNOSTIC_ACP_BINARY;
const sourceArgs = JSON.parse(process.env.GNOSTIC_ACP_PROFILE_SOURCE_ARGS ?? "[]");
if (!binary || !Array.isArray(sourceArgs)) throw new Error("missing Gnostic ACP fixture configuration");

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

  const client = new ACPClient({ profile, cwd });
  await client.start();
  if (!client.supportsSessionList) throw new Error("Gnostic did not advertise stable session/list");
  const created = await client.newSession(cwd);
  if (typeof created.sessionId !== "string") throw new Error("Gnostic did not create an ACP session");
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
