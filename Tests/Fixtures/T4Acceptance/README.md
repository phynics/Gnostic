# T4 acceptance fixtures

These files support the [T4 owner acceptance runbook](../../../Documentation/Acceptance/T4-owner-acceptance.md).
They drive a release `gnostic` build over its public surfaces: `gnostic serve`,
`gnostic acp`, and the Gnostic wire. None of them imports a Gnostic Swift
symbol except `gnostic-workspace-attach`.

| File | Purpose |
| --- | --- |
| `render.mjs` | Writes the Node manifests, the Workspace files, and stable UUIDs into a work directory. |
| `manifests/node-a.template.json` | Node A: one Runtime instance and its default Timeline. |
| `manifests/node-b.template.json` | Node B: one `filesystem` Workspace. |
| `container-shell.sh` | Opens an interactive shell in the pinned development container, or runs one command in it. `make shell` cannot. A command holds the build directory lock and may write it. A shell holds no lock and mounts the build directory read-only. |
| `journal.mjs` | Reads a Timeline journal. It parses the preserved frame text of an `acpUpdate`, strips a byte order mark, and reports a frame it cannot read instead of stopping. `t4.sh` calls it. |
| `selftest.sh` | Checks the lock behavior of `container-shell.sh` with a fake runtime, and `journal.mjs` with journal-shaped records. Needs `sh`, `flock` and `node`; no container. |
| `t4.sh` | Shell functions that start and stop the broker and the Nodes, run the client, and print a Timeline journal (`t4_journal_summary`, `t4_journal_text`). |
| `client.mjs` | An ACP v2 client that spawns `gnostic acp` and answers permission requests. |
| `package.json`, `package-lock.json` | Pin `@agentclientprotocol/sdk` `2.0.0`, the same version as the `ACPAgent` fixture. |

The deterministic Runtime is [`Tests/Fixtures/ACPAgent/agent.mjs`](../ACPAgent/agent.mjs).
The reference Runtime is the `gnostic-pk-runtime` product. The attach tool is the
`gnostic-workspace-attach` product, built from `Sources/GnosticWorkspaceAttach`.

## `render.mjs` options

| Option | Default | Meaning |
| --- | --- | --- |
| `--work <dir>` | required | Output directory. A second run reuses `ids.json`. |
| `--repo <dir>` | required | Repository root, used to find `agent.mjs`. |
| `--runtime fixture\|reference` | `fixture` | Which Runtime Node A launches. |
| `--pk-runtime <path>` | none | Path to `gnostic-pk-runtime`. Required for `--runtime reference`. |
| `--node <command>` | `node` | The command that runs `agent.mjs`. |
| `--broker-host`, `--broker-port` | `127.0.0.1`, `1883` | The broker address. |
| `--namespace <name>` | random `t4-xxxxxxxx` | The MQTT namespace, so a stale Node on a shared broker cannot interfere. |
| `--extra-timelines <n>` | `0` | Add `n` Timelines to the Node A manifests. They share the Runtime instance, and they let you check that a Node with many Timelines stays responsive. |
| `--print-env` | off | Print `export` lines for the shell instead of a summary. |

With `--runtime fixture`, `render.mjs` writes these Node A manifests. They differ
only in the Runtime's environment:

| Manifest | Fixture behavior |
| --- | --- |
| `node-a.json` | A prompt containing `[fixture:workspace-tool]` reads `note.txt` through the gateway. |
| `node-a.permission-approve.json` | The Runtime sends `session/request_permission` and requires the `allow-once` option back. |
| `node-a.permission-deny.json` | The same request. The Runtime requires `reject-once`. |
| `node-a.permission-unanswered.json` | The same request. The Runtime requires the `cancelled` outcome. |
| `node-a.large.json` | The Workspace tool reads `large.txt`, which is 6,200 bytes. |

The Runtime writes these files under `<work>/fixture/`:

| File | Content |
| --- | --- |
| `prompts.log` | One line per `session/prompt` that reached the Runtime. |
| `starts.log` | One line per Runtime process start. |
| `resumes.log` | One line per `session/resume` the Runtime received. |
| `permission.log` | The outcome the Runtime received for its permission request. |
| `mcp.log` | One JSON line per Workspace gateway request the Runtime made, with its outcome: `success`, `json-rpc-error`, `no-response`, `http-error` or `invalid-response`. |
| `wire.log` | The order of prompts and cancels the Runtime saw. |
| `sessions.json` | The Runtime's own session store. |

## `client.mjs` options

Run `node client.mjs --prompt <text> [options] -- gnostic acp ...`. The command
after `--` is spawned, and the client speaks ACP v2 on its stdio.

| Option | Default | Meaning |
| --- | --- | --- |
| `--prompt <text>` | none | Send a prompt. Repeat the option to send more Turns in order. |
| `--client-turn-id <id>` | generated | Name the first Turn. A retry with the same ID is idempotent. |
| `--permission approve\|deny\|cancel\|ignore` | `approve` | `approve` selects `allow_once`. `deny` selects `reject_once`. `cancel` answers the `cancelled` outcome at once. `ignore` never answers. |
| `--cwd <path>` | current directory | The Session `cwd`. |
| `--state-file <path>` | none | Write the session and Timeline IDs after `session/new`. |
| `--resume <path>` | none | Call `session/resume` for the session in this file instead of `session/new`. |
| `--on-session <command>` | none | Run a shell command after the session is ready. It sees `T4_SESSION_ID` and `T4_SESSION_TIMELINE_ID`. |
| `--after-first-turn <command>` | none | Run a shell command after the first Turn ends, with the same environment. |
| `--timeout-ms <n>` | 60000 | How long to wait for each Turn to end. |
| `--print-max <n>` | 160 | The most characters printed for one text. |
| `--hold-open-ms <n>` | 0 | Wait this long after the last Turn before closing the session. |
| `--no-close` | off | Leave the session open on exit. |
| `--answer-delay-ms <n>` | 0 | Wait before answering a permission request. The request is printed at once, so a drill can act while the Turn waits. |
| `--text-totals` | off | After each Turn, print how many bytes of `agent_message_chunk` text arrived. |
| `--elapsed` | off | Start each line with the seconds since the client started. |

The exit status is 0 when every Turn ended with an `idle` update, 1 when a
prompt failed or timed out, and 2 for a usage error.
