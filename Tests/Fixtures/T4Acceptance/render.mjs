#!/usr/bin/env node
// Renders the T4 acceptance manifests and fixture files into a work directory.
//
// Usage:
//   node render.mjs --work <dir> --repo <repository root> [--runtime fixture|reference]
//                   [--pk-runtime <path to gnostic-pk-runtime>] [--node <node executable>]
//                   [--broker-host 127.0.0.1] [--broker-port 1883] [--namespace <name>]
//                   [--extra-timelines <n>] [--print-env]
//
// It writes, under <dir>:
//   ids.json                      The generated UUIDs. A second run reuses them.
//   node-a.json                   Node A: the Runtime instance and its default Timeline.
//   node-a.<variant>.json         The same Node with one fixture behavior changed.
//   node-b.json                   Node B: one `filesystem` Workspace.
//   workspace-root/               The files Node B serves: note.txt and large.txt.
//   state-a/ state-b/ client-state/ fixture/   Empty state directories.
// With --print-env it prints `export NAME=value` lines for a POSIX shell.

import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const here = dirname(fileURLToPath(import.meta.url));
const { values } = parseArgs({
  options: {
    work: { type: "string" },
    repo: { type: "string" },
    runtime: { type: "string", default: "fixture" },
    "pk-runtime": { type: "string" },
    node: { type: "string", default: "node" },
    "broker-host": { type: "string", default: "127.0.0.1" },
    "broker-port": { type: "string", default: "1883" },
    namespace: { type: "string" },
    "extra-timelines": { type: "string", default: "0" },
    "print-env": { type: "boolean", default: false },
  },
});
if (!values.work || !values.repo) fail("--work and --repo are required.");
if (!["fixture", "reference"].includes(values.runtime)) fail("--runtime must be fixture or reference.");
if (values.runtime === "reference" && !values["pk-runtime"]) fail("--runtime reference needs --pk-runtime.");
const work = resolve(values.work);
const repo = resolve(values.repo);
await mkdir(work, { recursive: true });

// Stable identities: render twice, get the same Nodes.
const idsPath = join(work, "ids.json");
const ids = existsSync(idsPath)
  ? JSON.parse(await readFile(idsPath, "utf8"))
  : {
      namespace: values.namespace ?? `t4-${randomUUID().slice(0, 8)}`,
      NODE_A_ID: randomUUID(), NODE_B_ID: randomUUID(), RUNTIME_ID: randomUUID(),
      TIMELINE_ID: randomUUID(), WORKSPACE_ID: randomUUID(),
    };
const extraTimelines = Number(values["extra-timelines"]);
if (!Number.isInteger(extraTimelines) || extraTimelines < 0) fail("--extra-timelines must be a non-negative integer.");
ids.EXTRA_TIMELINE_IDS = Array.from({ length: extraTimelines }, (_, index) => ids.EXTRA_TIMELINE_IDS?.[index] ?? randomUUID());
if (values.namespace) ids.namespace = values.namespace;
await writeFile(idsPath, `${JSON.stringify(ids, null, 2)}\n`);

const dirs = {
  workspaceRoot: join(work, "workspace-root"),
  stateA: join(work, "state-a"), stateB: join(work, "state-b"),
  clientState: join(work, "client-state"), fixture: join(work, "fixture"), pk: join(work, "pk-state"),
};
for (const dir of Object.values(dirs)) await mkdir(dir, { recursive: true });

// The Workspace content. large.txt is 6,200 bytes of numbered lines, well over 2 KiB.
await writeFile(join(dirs.workspaceRoot, "note.txt"), "T4 note: the remote Workspace answered.\n");
const large = Array.from({ length: 200 }, (_, index) => `line ${String(index + 1).padStart(3, "0")} ${"x".repeat(21)}`);
await writeFile(join(dirs.workspaceRoot, "large.txt"), `${large.join("\n")}\n`);

const fixtureFile = (name) => join(dirs.fixture, name);
const fixtureEnv = (extra = {}) => ({
  GNOSTIC_ACP_FIXTURE_STATE: fixtureFile("sessions.json"),
  GNOSTIC_ACP_FIXTURE_MCP: "1",
  GNOSTIC_ACP_FIXTURE_EXPECTED_WORKSPACE_TOOL_COUNT: "2",
  GNOSTIC_ACP_FIXTURE_WORKSPACE_TOOL_SUFFIX: "__read_file",
  GNOSTIC_ACP_FIXTURE_WORKSPACE_TOOL_ARGUMENTS: '{"path":"note.txt"}',
  GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE: fixtureFile("prompts.log"),
  GNOSTIC_ACP_FIXTURE_START_COUNT_FILE: fixtureFile("starts.log"),
  GNOSTIC_ACP_FIXTURE_RESUME_REQUEST_FILE: fixtureFile("resumes.log"),
  GNOSTIC_ACP_FIXTURE_WIRE_LOG_FILE: fixtureFile("wire.log"),
  GNOSTIC_ACP_FIXTURE_PERMISSION_RESULT_FILE: fixtureFile("permission.log"),
  GNOSTIC_ACP_FIXTURE_MCP_DIAGNOSTICS_FILE: fixtureFile("mcp.log"),
  ...extra,
});

// Each variant changes only the Runtime's environment.
const variants = values.runtime === "reference" ? { "": {} } : {
  "": {},
  "permission-approve": { GNOSTIC_ACP_FIXTURE_PERMISSION: "1", GNOSTIC_ACP_FIXTURE_PERMISSION_OUTCOME: "selected:allow-once" },
  "permission-deny": { GNOSTIC_ACP_FIXTURE_PERMISSION: "1", GNOSTIC_ACP_FIXTURE_PERMISSION_OUTCOME: "selected:reject-once" },
  "permission-unanswered": { GNOSTIC_ACP_FIXTURE_PERMISSION: "1", GNOSTIC_ACP_FIXTURE_PERMISSION_OUTCOME: "cancelled" },
  large: { GNOSTIC_ACP_FIXTURE_WORKSPACE_TOOL_ARGUMENTS: '{"path":"large.txt"}' },
};

const template = JSON.parse(await readFile(join(here, "manifests", "node-a.template.json"), "utf8"));
for (const [variant, extra] of Object.entries(variants)) {
  const runtime = values.runtime === "reference"
    ? {
        RUNTIME_COMMAND: resolve(values["pk-runtime"]), RUNTIME_ARGS: [],
        RUNTIME_ENV: { GNOSTIC_PK_SCRIPTED: "1", GNOSTIC_PK_STATE_DIR: dirs.pk, GNOSTIC_PK_FIXTURE_TOOL_NAME: `workspace_${ids.WORKSPACE_ID.replaceAll("-", "")}__read_file` },
      }
    : {
        RUNTIME_COMMAND: values.node, RUNTIME_ARGS: [join(repo, "Tests/Fixtures/ACPAgent/agent.mjs")],
        RUNTIME_ENV: fixtureEnv(extra),
      };
  const manifest = fill(template, {
    BROKER_HOST: values["broker-host"], BROKER_PORT: Number(values["broker-port"]), NAMESPACE: ids.namespace, ...ids, ...runtime,
  });
  // Extra manifest Timelines share the Runtime instance. They load at start, each with its own session.
  ids.EXTRA_TIMELINE_IDS.forEach((id, index) => manifest.timelines.push({
    id, kind: "timeline", title: `T4 extra Timeline ${index + 1}`, runtimeInstanceID: ids.RUNTIME_ID, flags: [], attachments: [],
  }));
  const settings = manifest.runtimeInstances[0].backend.settings;
  // The manifest stores `args` and `env` as JSON text.
  settings.args = JSON.stringify(settings.args);
  settings.env = JSON.stringify(settings.env);
  await writeFile(join(work, variant ? `node-a.${variant}.json` : "node-a.json"), `${JSON.stringify(manifest, null, 2)}\n`);
}
const nodeB = fill(JSON.parse(await readFile(join(here, "manifests", "node-b.template.json"), "utf8")), {
  BROKER_HOST: values["broker-host"], BROKER_PORT: Number(values["broker-port"]), NAMESPACE: ids.namespace,
  ...ids, WORKSPACE_ROOT: dirs.workspaceRoot,
});
await writeFile(join(work, "node-b.json"), `${JSON.stringify(nodeB, null, 2)}\n`);

if (values["print-env"]) {
  const exported = {
    T4_WORK: work, T4_NAMESPACE: ids.namespace, T4_NODE_A_ID: ids.NODE_A_ID, T4_NODE_B_ID: ids.NODE_B_ID,
    T4_RUNTIME_ID: ids.RUNTIME_ID, T4_DEFAULT_TIMELINE_ID: ids.TIMELINE_ID, T4_WORKSPACE_ID: ids.WORKSPACE_ID,
    T4_BROKER_HOST: values["broker-host"], T4_BROKER_PORT: values["broker-port"],
  };
  for (const [name, value] of Object.entries(exported)) console.log(`export ${name}='${value}'`);
} else {
  console.log(`rendered ${Object.keys(variants).length} Node A manifest(s) and node-b.json in ${work}`);
}

function fill(node, bindings) {
  if (typeof node === "string") {
    const whole = node.match(/^@@([A-Z_]+)@@$/);
    if (whole) {
      if (!(whole[1] in bindings)) fail(`no value for @@${whole[1]}@@`);
      return structuredClone(bindings[whole[1]]);
    }
    return node.replace(/@@([A-Z_]+)@@/g, (_, name) => {
      if (!(name in bindings)) fail(`no value for @@${name}@@`);
      return String(bindings[name]);
    });
  }
  if (Array.isArray(node)) return node.map((item) => fill(item, bindings));
  if (node && typeof node === "object") return Object.fromEntries(Object.entries(node).map(([key, value]) => [key, fill(value, bindings)]));
  return node;
}

function fail(message) {
  console.error(`render.mjs: ${message}`);
  process.exit(2);
}
