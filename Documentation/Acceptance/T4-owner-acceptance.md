# Run the T4 owner acceptance drills

This runbook runs the five T4 drills from
[#552](https://github.com/phynics/Gnostic/issues/552) against a release build of
Gnostic, on macOS and Linux. You start two Nodes on one broker, drive them with an
ACP client, and read the Timeline journal on disk.

The fixtures that the commands use are in
[`Tests/Fixtures/T4Acceptance`](../../Tests/Fixtures/T4Acceptance/README.md).
That page lists every option. The 0.5.0 contract that the drills check is in the
[compatibility declaration](../Compatibility/0.5.0.md).

## What was proven where

The commands and outputs below come from a release build of `main` at `7e2947f`
with the fixtures from this change applied. Linux outputs were captured on
2026-11-02 in the development container (x86_64, 4 cores, Podman 5.8.9, Swift
6.4.0).

**How the Linux run was made.** A script extracted every `sh` code block from this
file and ran them in order, from the build through the reference Runtime and the
clean-up, in one container shell session: the shell was opened once with
`container-shell.sh`, and every Node and the broker were started and stopped only
by the commands in the blocks. The replay ran the file as it stands apart from
the prose and expected outputs, which were corrected from the replay. It did not run:

- the macOS commands (no Mac was available);
- the by-hand `gnostic-workspace-attach` command, which has placeholders (the
  `--on-session` hook runs the same command in every drill);
- the live-provider recipe at the end of the reference Runtime section.

The replay fed each block to the shell from a file, with standard input closed,
and did not type it. Run IDs, process IDs, and times differ on each run, and so
does `elapsedSeconds` by a second or two. Journal sequence numbers in the Drill 4
steps 5 and 6 depend on the commands before them, so they match only if you ran
the drills in this order. Nobody has run this runbook on macOS or with a live
model provider.

| Part | Linux, dev container | macOS | Live provider |
| --- | --- | --- | --- |
| Release build of `gnostic`, `gnostic-pk-runtime`, `gnostic-workspace-attach` | Run | Not run on current code | Not applicable |
| Broker, two Nodes, Workspace attach | Run | Not run on current code | Not applicable |
| Drill 1 with the fixture Runtime | Run | Not run on current code | Not applicable |
| Drill 1 with the reference Runtime (scripted model) | Run | Not run on current code | Not run |
| Drills 2 to 5 | Run | Not run on current code | Not applicable |
| Drill 4 with a Workspace call in flight, and with only the broker stopped | Run | Not run on current code | Not applicable |

Drill 4 does not meet #552 T4 item 4: the client and the journal cannot tell the
three loss cases apart, and the Nodes do not rejoin a restarted broker. Findings 6
to 8 record this. Read them before you sign off.

Every macOS command and every macOS output in this runbook is untested. An
earlier version of this runbook also had no macOS run. Treat the macOS steps as a
draft until someone runs them.

The proof runs on the earlier version of the code produced four findings. The
runs on `7e2947f` reproduced one of them. See
[Findings from the proof runs](#findings-from-the-proof-runs).

## Before you start

You need these tools. The Linux column lists what the development container
already provides.

| Tool | Linux | macOS |
| --- | --- | --- |
| Swift 6.4.0 toolchain | In the container image `swift:6.4.0-noble` | Install Swift 6.4.0 from swift.org. `Package.swift` declares `swift-tools-version: 6.4` and macOS 26. Not run on current code. |
| Container runtime | `podman` or `docker`, for `container-shell.sh` | Not needed |
| Node.js 22 | In the container (22.18.0) | `brew install node@22`. Not run on current code. |
| Mosquitto broker and `mosquitto_pub` | In the container | `brew install mosquitto`. Not run on current code. |
| Git | From your distribution | Xcode command line tools |

Run `swift --version` and confirm that it prints `Swift version 6.4`. In the
container it prints `Swift version 6.4 (swift-6.4-RELEASE)`.

## Build the release binaries

You need three executables: `gnostic`, `gnostic-pk-runtime`, and
`gnostic-workspace-attach`. A release build took about 10 minutes on an idle
4-core machine with a warm package cache. Expect about 30 minutes from a cold
cache on a loaded machine.

On Linux, build inside the container. `make shell` does not give you a shell:
the container runner starts the container without stdin, so `bash` exits at once.
[`container-shell.sh`](../../Tests/Fixtures/T4Acceptance/container-shell.sh) starts
the same image with the same mounts and the same host user, and it keeps the
terminal. Run it from the repository root. Without arguments it opens a shell.
With arguments it runs one command and exits. It stops the container after
`CONTAINER_TIMEOUT` seconds, 7200 by default.

The script takes the build directory lock only when you give it a command, as the
Make targets do. The command waits up to `BUILD_LOCK_TIMEOUT` seconds, 1800 by
default, so a `make clean` or `make build` in the same worktree cannot remove
artifacts during the build, and the build cannot start during theirs. A shell
takes no lock: it stays open for hours, and a lock would block every Make target
in the worktree for as long. The shell mounts the build directory read-only,
because the drills only run the built binaries. While a shell is open, do not run
`make clean` or a build for the same worktree and configuration.
[`selftest.sh`](../../Tests/Fixtures/T4Acceptance/selftest.sh) checks the locking
with a fake runtime.

1. Resolve the dependencies:

   ```sh
   make resolve
   ```

2. Build the three products in the container. The first run builds every
   dependency:

   ```sh
   Tests/Fixtures/T4Acceptance/container-shell.sh bash -c '
       FLAGS="--cache-path /workspace/.swiftpm-cache --disable-automatic-resolution --build-system native -c release"
       swift build $FLAGS --product gnostic &&
       swift build $FLAGS --product gnostic-pk-runtime &&
       swift build $FLAGS --product gnostic-workspace-attach &&
       swift build $FLAGS --show-bin-path'
   ```

   The last command prints the directory that holds the binaries. Keep it. On
   Linux x86_64 it is `/workspace/.build/x86_64-unknown-linux-gnu/release`. SwiftPM
   prints a deprecation warning for `--build-system native`. The repository pins it
   on purpose.

On macOS (not run on current code), build natively from the repository root:

```sh
swift build -c release --product gnostic
swift build -c release --product gnostic-pk-runtime
swift build -c release --product gnostic-workspace-attach
swift build -c release --show-bin-path
```

## Prepare the shell

Run the rest of this runbook in one shell. On Linux, open a new container shell
with `Tests/Fixtures/T4Acceptance/container-shell.sh`. Every Node and the broker
run in the background of that shell, and the helpers write their logs under
`$T4_WORK/logs`. The shell mounts the release build directory read-only, so you
cannot rebuild in it. The container is removed when you leave the shell, so copy
any output you want to keep out of `$T4_WORK` first. The container has no `git`
metadata for a worktree, so run `git rev-parse HEAD` on the host.

1. Set the paths. `REPO` is the repository root and `T4_BIN` is the directory
   that `swift build --show-bin-path` printed. On macOS it is
   `$REPO/.build/release`. The values below are for Linux x86_64 in the
   container:

   ```sh
   export REPO=/workspace
   export T4_BIN=/workspace/.build/x86_64-unknown-linux-gnu/release
   export T4_WORK=$(mktemp -d)
   export T4_FIXTURES=$REPO/Tests/Fixtures/T4Acceptance
   ```

2. Confirm the version:

   ```sh
   "$T4_BIN/gnostic" --version
   ```

   Expected output:

   ```text
   0.5.0
   ```

3. Install the fixture dependencies. Both packages pin `@agentclientprotocol/sdk`
   `2.0.0`:

   ```sh
   npm ci --prefix "$REPO/Tests/Fixtures/ACPAgent"
   npm ci --prefix "$T4_FIXTURES"
   ```

4. Render the manifests and load the helpers. If another process already listens
   on port 1883 (a macOS host, for example; the Linux container has its own
   network), add `--broker-port 1884`:

   ```sh
   eval "$(node "$T4_FIXTURES/render.mjs" --work "$T4_WORK" --repo "$REPO" --print-env)"
   . "$T4_FIXTURES/t4.sh"
   ```

   `render.mjs` generates fresh UUIDs and an MQTT namespace such as `t4-4843e2a0`,
   so the run cannot meet a stale Node on a shared broker. It writes the files
   described in [Manifests and startup order](#manifests-and-startup-order) and
   exports `T4_NODE_A_ID`, `T4_NODE_B_ID`, `T4_RUNTIME_ID`, `T4_WORKSPACE_ID`,
   `T4_NAMESPACE`, and the broker address.

5. Check both manifests before you start anything:

   ```sh
   "$T4_BIN/gnostic" config validate --config "$T4_WORK/node-a.json"
   "$T4_BIN/gnostic" config validate --config "$T4_WORK/node-b.json"
   "$T4_BIN/gnostic" doctor --config "$T4_WORK/node-b.json"
   ```

   Expected output:

   ```text
   Configuration is valid.
   Configuration is valid.
   [ok] manifest: Configuration is valid. (<T4_WORK>/node-b.json)
   [ok] workspace: Workspace 'T4 files' path exists. (<T4_WORK>/workspace-root)
   Healthy: 0 error(s), 0 warning(s).
   ```

## Manifests and startup order

`render.mjs` fills two templates:
[`node-a.template.json`](../../Tests/Fixtures/T4Acceptance/manifests/node-a.template.json)
and
[`node-b.template.json`](../../Tests/Fixtures/T4Acceptance/manifests/node-b.template.json).
Open the rendered files in `$T4_WORK` when you want to see or change a value.

**Node B** (`node-b.json`) hosts one Workspace. `config workspace add` writes the
kind `echo`, so the `kind` must be set by hand. The template does it:

```json
{
	"id": "<T4_WORKSPACE_ID>",
	"kind": "filesystem",
	"name": "T4 files",
	"uri": "<T4_WORK>/workspace-root"
}
```

Node B serves two files from that root: `note.txt` (40 bytes) and `large.txt`
(6,200 bytes). Its tools are `list_directory` and `read_file`.

**Node A** (`node-a.json`) hosts one Runtime instance and its default Timeline.
The Runtime launch fields are the only part that changes between Runtimes:

| Runtime | `command` | `args` | `env` keys |
| --- | --- | --- | --- |
| Fixture (default) | `node` | `["<REPO>/Tests/Fixtures/ACPAgent/agent.mjs"]` | `GNOSTIC_ACP_FIXTURE_*` |
| Reference (`--runtime reference --pk-runtime <path>`) | `<T4_BIN>/gnostic-pk-runtime` | `[]` | `GNOSTIC_PK_SCRIPTED=1`, `GNOSTIC_PK_STATE_DIR` |

The fixture Runtime is deterministic and needs no provider. It answers a prompt
with `reply: <prompt>`, reads a Workspace file when the prompt contains
`[fixture:workspace-tool]`, and holds a Turn open for 20 seconds when the prompt
contains `[fixture:wait]`. The reference Runtime in `GNOSTIC_PK_SCRIPTED` mode
also needs no provider. Its scripted model answers `scripted response: <prompt>`.

For the fixture Runtime, `render.mjs` also writes four variants of `node-a.json`.
They differ only in the Runtime's environment: `node-a.permission-approve.json`,
`node-a.permission-deny.json`, `node-a.permission-unanswered.json`, and
`node-a.large.json`.

Start the processes in this order. Node B comes first so that its Workspace is
advertised before you attach it. Wait for each `online` line.

```sh
t4_broker_start
t4_node_start b "$T4_WORK/node-b.json" "$T4_WORK/state-b"
t4_node_start a "$T4_WORK/node-a.json" "$T4_WORK/state-a"
```

Expected output:

```text
broker online at 127.0.0.1:1883 (pid <pid>)
node b online (pid <pid>)
node a online (pid <pid>)
```

Confirm that both Nodes are visible on the broker:

```sh
"$T4_BIN/gnostic" inspect list --config "$T4_WORK/node-a.json"
```

Expected output, one object per line, in any order. Run it a second time if a
line is missing, because discovery takes a moment:

```text
me.atkn.gnostic.RuntimeInstance  <runtime-id>  <node-a-provider>  gnostic-deterministic-acp-fixture
me.atkn.gnostic.Workspace  <workspace-id>  <node-b-provider>  <T4_WORK>/workspace-root  available uri=<T4_WORK>/workspace-root tools=[list_directory,read_file]
me.atkn.gnostic.Timeline  <timeline-id>  <node-a-provider>  T4 default Timeline
```

`t4_node_start` waits for the log line `advertised objects`, which `gnostic serve`
writes after it connects to the broker. That line is the reliable sign that a Node
is up. `gnostic serve` writes its `gnostic serve online` line to standard output
without flushing, so with output in a file the line appears only when the Node
exits (finding 4).

## Attach the Workspace to a Timeline

`gnostic` has no command that attaches a Workspace to a running Timeline. Two
mechanisms exist, and only one fits this journey.

- **The `attachments` manifest field.** Set `scope` to `network` and `uri` to the
  Workspace's advertised `uri`. `gnostic config timeline attach-workspace
  <timeline-id> <workspace-id> --network <uri>` writes it. Node A then advertises
  the Workspace in the Timeline's `attachedWorkspaceIDs`, and the Workspace
  resolves lazily. This works only for a Timeline that is listed in the
  manifest. `gnostic acp` does not use such a Timeline. Each `session/new`
  creates a new Timeline that no manifest lists. An earlier proof run showed that Node A
  advertises the attachment. It did not exercise a tool call through it, and
  the runs on `7e2947f` did not exercise this path either.
- **A client call.** The `workspace.attach` operation attaches a discovered
  Workspace to any Timeline, including one that `session/new` just created. No
  `gnostic` command makes this call, so this change adds the executable
  `gnostic-workspace-attach`. It is a short consumer of the public
  `GnosticClient` API (85 lines) that makes the same call as the two-Node
  integration test. It compiles unchanged against the `GnosticClient` API of
  `7e2947f`.

`client.mjs --on-session "$T4_ATTACH_CMD"` runs the attach right after
`session/new`. The client exports the new Timeline ID as
`T4_SESSION_TIMELINE_ID`, and `$T4_ATTACH_CMD` expands to:

```sh
gnostic-workspace-attach --host 127.0.0.1 --port 1883 --namespace <T4_NAMESPACE> --workspace <T4_WORKSPACE_ID> --timeline "$T4_SESSION_TIMELINE_ID"
```

To attach by hand, run that command with a Timeline ID. Expected output:

```text
attached workspace <workspace-id> to timeline <timeline-id> (effective status: available)
```

## Drill 1: Run the two-Node operator journey

This drill checks that a client Turn on Node A reaches a Workspace on Node B and
that Node A keeps the authoritative Timeline journal.

1. Run one Turn. The client creates a session, attaches the Workspace, sends the
   prompt, approves the Workspace permission request, and closes the session:

   ```sh
   t4_client --on-session "$T4_ATTACH_CMD" \
       --prompt 'read the remote file [fixture:workspace-tool]' \
       --client-turn-id journey-1 --state-file "$T4_WORK/session.json"
   ```

   Expected output:

   ```text
   initialize: protocolVersion=2
   session/new: sessionId=<session-id> timeline=<timeline-id>
   attached workspace <workspace-id> to timeline <timeline-id> (effective status: available)
   on-session: exit 0
   session/prompt 1: "read the remote file [fixture:workspace-tool]" clientTurnID=journey-1
   update user_message: "read the remote file [fixture:workspace-tool]"
   update state_update: state=running
   permission request 1: "Run Workspace tool Read file" options=allow_once,reject_once
   permission request 1: answered allow_once
   update agent_message_chunk: "fixture "
   update agent_message_chunk: "reply: read the remote file [fixture:workspace-tool] | T4 note: the remote Workspace answered.\\n"
   update tool_call_update: Inspect fixture input status=pending
   update tool_call_update: Inspect fixture input status=completed
   update state_update: state=idle stopReason=end_turn
   session/prompt 1: accepted messageId=acp:user:journey-1
   session/close: ok
   summary: permissionRequests=1 failed=false elapsedSeconds=8
   ```

   The text `T4 note: the remote Workspace answered.` is the content of `note.txt`
   on Node B. The Runtime on Node A read it through the Gnostic MCP gateway.

2. Read the Timeline journal on Node A:

   ```sh
   TIMELINE=$(t4_session_timeline "$T4_WORK/session.json")
   ls -l "$(t4_journal "$TIMELINE")"
   t4_journal_summary "$TIMELINE"
   ```

   Expected output:

   ```text
   -rw------- 1 <user> <group> 7178 <date> <T4_WORK>/state-a/timeline-journals/<node-a-id>/timeline-<timeline-id>-v1.jsonl
     1 seq=1 replayEpochStarted
     2 seq=2 timelineCreated
     3 seq=3 sessionTransition live
     4 seq=4 workspaceAttached network
     5 seq=5 turnAdmitted
     6 seq=6 permissionDecision approved
     7 seq=7 acpUpdate user_message
     8 seq=8 acpUpdate state_update
     9 seq=9 acpUpdate agent_message_chunk
    10 seq=10 acpUpdate agent_message_chunk
    11 seq=11 acpUpdate tool_call_update
    12 seq=12 acpUpdate tool_call_update
    13 seq=13 acpUpdate state_update
    14 seq=14 turnCompleted completed
   ```

   Check these facts. The journal file has mode `0600`. The sequence numbers are
   contiguous. `turnAdmitted` comes before every update. `workspaceAttached` has
   the scope `network`. `turnCompleted` has the outcome `completed`. The
   file size and timestamps differ on your machine.

   An `acpUpdate` record stores the Runtime's `session/update` frame as the exact
   JSON text that the Runtime sent, in a string field. `t4_journal_summary` parses
   that text to print the update kind. Open the file to see it.

3. Check that Node B holds no journal:

   ```sh
   ls "$T4_WORK/state-b"
   ```

   Expected output: nothing. The Timeline lives on Node A, and Node B only
   serves the Workspace.

4. Check that Node A stays responsive with more live sessions than the machine has
   cores. Each session holds its own Timeline, its own Workspace gateway, and its
   own Runtime process. An earlier build stalled here on a machine with 4 or fewer
   cores: the first Turn never reached the Runtime, and `workspace.attach` timed
   out (finding 1, now resolved). Open six more sessions, attach the Workspace to
   each, and read the file through each:

   ```sh
   for count in 1 2 3 4 5 6; do
       t4_client --on-session "$T4_ATTACH_CMD" --prompt "read the remote file [fixture:workspace-tool]" \
           --state-file "$T4_WORK/many-$count.json" --no-close | grep -E "FAILED|TIMED OUT|summary|T4 note" | cut -c1-120
   done
   "$T4_BIN/gnostic" inspect list --config "$T4_WORK/node-a.json" | grep -c 'me.atkn.gnostic.Timeline'
   ```

   Expected output, repeated six times and then the Timeline count:

   ```text
   update agent_message_chunk: "reply: read the remote file [fixture:workspace-tool] | T4 note: the remote Workspace answer
   summary: permissionRequests=1 failed=false elapsedSeconds=7
   ...
   8
   ```

   The count is the default Timeline, the one from step 1, and six new ones. On the
   4-core proof machine, all six Turns passed with seven live sessions, which is
   more than the two that stalled the earlier build. The proof machine ran the
   `fixture` Runtime for these sessions. The reference Runtime run at the end of
   this runbook repeats the check with 9 manifest Timelines and 6 live sessions.

## Drill 2: Answer, refuse, and ignore a permission request

This drill checks the three outcomes of a Runtime permission request. The fixture
Runtime sends `session/request_permission`, and the matching manifest variant
tells it which outcome it must receive. If the Runtime receives a different
outcome, it fails the Turn.

The loop stops the Node A from Drill 1 first. Node B can keep running, because
these variants do not use the Workspace. The loop restarts Node A once per
variant. The third variant waits for the 120-second bound on an unanswered
request, so allow about two and a half minutes for it.

```sh
t4_node_stop a
for variant in approve deny unanswered; do
	t4_node_start a "$T4_WORK/node-a.permission-$variant.json" "$T4_WORK/state-a"
	case $variant in approve) answer=approve ;; deny) answer=deny ;; unanswered) answer=ignore ;; esac
	rm -f "$T4_WORK/fixture/permission.log"
	t4_client --permission $answer --timeout-ms 200000 --elapsed \
		--state-file "$T4_WORK/session-$variant.json" --prompt 'permission drill'
	echo "Runtime received: $(cat "$T4_WORK/fixture/permission.log")"
	t4_journal_summary "$(t4_session_timeline "$T4_WORK/session-$variant.json")" | grep -E "permissionDecision|turnCompleted"
	t4_node_stop a
done
```

Expected output for `approve`:

```text
[+  5s] initialize: protocolVersion=2
[+  5s] session/new: sessionId=<session-id> timeline=<timeline-id>
[+  5s] session/prompt 1: "permission drill"
[+  5s] update user_message: "permission drill"
[+  5s] update state_update: state=running
[+  5s] permission request 1: "Inspect fixture input" options=allow_once,reject_once
[+  5s] permission request 1: answered allow_once
[+  5s] update agent_message_chunk: "fixture "
[+  5s] update agent_message_chunk: "reply: permission drill"
[+  5s] update tool_call_update: Inspect fixture input status=pending
[+  5s] update tool_call_update: Inspect fixture input status=completed
[+  5s] update state_update: state=idle stopReason=end_turn
[+  5s] session/prompt 1: accepted messageId=<message-id>
[+  5s] session/close: ok
[+  5s] summary: permissionRequests=1 failed=false elapsedSeconds=5
Runtime received: {"optionId":"allow-once","outcome":"selected"}
  7 seq=7 permissionDecision approved
 13 seq=13 turnCompleted completed
```

Expected output for `deny`. The lines that match `approve` are left out:

```text
...
[+  5s] permission request 1: "Inspect fixture input" options=allow_once,reject_once
[+  5s] permission request 1: answered reject_once
...
[+  5s] update state_update: state=idle stopReason=end_turn
...
[+  5s] summary: permissionRequests=1 failed=false elapsedSeconds=5
Runtime received: {"optionId":"reject-once","outcome":"selected"}
  7 seq=7 permissionDecision denied
 13 seq=13 turnCompleted completed
```

Expected output for `unanswered`. The client never answers. After 120 seconds
Node A stops waiting. The lines that match `approve` are left out:

```text
...
[+  5s] permission request 1: "Inspect fixture input" options=allow_once,reject_once
[+  5s] permission request 1: not answering (waiting from t=5s)
[+125s] update agent_message_chunk: "fixture "
[+125s] update agent_message_chunk: "reply: permission drill"
...
[+125s] update state_update: state=idle stopReason=end_turn
...
[+125s] summary: permissionRequests=1 failed=false elapsedSeconds=125
Runtime received: {"outcome":"cancelled"}
  7 seq=7 permissionDecision unavailable
 13 seq=13 turnCompleted completed
```

Check these facts for `unanswered`. The Runtime received the ACP v2 outcome
`cancelled` and not a refusal such as `reject-once`. The journal records
`unavailable`, not `denied`. The Turn ended `completed` with `end_turn`, so the
unanswered request did not fail the Turn.

A client that answers `cancelled` at once (`--permission cancel`) gets the same
Runtime outcome and the same `unavailable` journal record without the wait.

## Drill 3: Restart Node A and resume the session

This drill checks that a restarted Node A recovers the Timeline from its journal
and that the client resumes the same session. It runs once after a clean stop and
once after an abrupt kill.

The Runtime keeps three logs in `$T4_WORK/fixture`. Clear them so that this drill
starts from empty logs. Node A is stopped at this point:

```sh
rm -f "$T4_WORK/fixture/starts.log" "$T4_WORK/fixture/resumes.log" "$T4_WORK/fixture/prompts.log"
t4_node_start a "$T4_WORK/node-a.json" "$T4_WORK/state-a"
t4_client --prompt 'first turn before the restart' --client-turn-id restart-1 \
	--state-file "$T4_WORK/session.json" --no-close
TIMELINE=$(t4_session_timeline "$T4_WORK/session.json")
t4_node_stop a
t4_node_start a "$T4_WORK/node-a.json" "$T4_WORK/state-a"
t4_client --resume "$T4_WORK/session.json" --prompt 'second turn after the restart' \
	--client-turn-id restart-2 --no-close
t4_journal_summary "$TIMELINE"
```

Expected output of the second client:

```text
initialize: protocolVersion=2
session/resume: sessionId=<session-id> timeline=<timeline-id>
session/prompt 1: "second turn after the restart" clientTurnID=restart-2
update user_message: "second turn after the restart"
update state_update: state=running
update agent_message_chunk: "fixture "
update agent_message_chunk: "reply: second turn after the restart"
update tool_call_update: Inspect fixture input status=pending
update tool_call_update: Inspect fixture input status=completed
update state_update: state=idle stopReason=end_turn
session/prompt 1: accepted messageId=acp:user:restart-2
summary: permissionRequests=0 failed=false elapsedSeconds=5
```

The session ID and the Timeline ID are the same as in the first client. Expected
journal summary:

```text
  1 seq=1 replayEpochStarted
  2 seq=2 timelineCreated
  3 seq=3 turnAdmitted
  4 seq=4 sessionTransition live
  ...
 12 seq=12 turnCompleted completed
 13 seq=13 replayEpochStarted
 14 seq=14 turnAdmitted
 15 seq=15 sessionTransition ambiguous
 16 seq=16 sessionTransition live
 17 seq=17 acpUpdate user_message
 ...
 24 seq=24 turnCompleted completed
```

Check these facts. The first record after the restart is a new
`replayEpochStarted`, so Node A reopened the same journal and kept the sequence
contiguous. The session passed through `ambiguous` before the Runtime confirmed
the resume, then became `live`. Nothing was lost or rewritten. Check the
Runtime side as well:

```sh
cat "$T4_WORK/fixture/starts.log"
cut -c1-90 "$T4_WORK/fixture/resumes.log"
```

Expected output: two `started` lines, because Node A started the Runtime twice,
and one `session/resume` request for the same Runtime session:

```text
started
started
{"sessionId":"fixture-session-12","cwd":"/tmp/gnostic-scratch-<uuid, cut at 90 characters>
```

Retry the first Turn by its ID. Node A returns the recorded Turn and does not send
a second prompt:

```sh
t4_client --resume "$T4_WORK/session.json" --prompt 'first turn before the restart' \
	--client-turn-id restart-1 --no-close
cat "$T4_WORK/fixture/prompts.log"
```

Expected output of the client: the recorded Turn, replayed. It starts with
`update user_message`, has no `running` update, ends with
`update state_update: state=idle stopReason=end_turn`, and reports
`failed=false`. Expected output of `prompts.log`: two lines, one per prompt the
Runtime ever received (`restart-1` and `restart-2`). The retry added none.

Now repeat the recovery after an abrupt loss. Kill Node A, restart it, and resume:

```sh
t4_node_kill a
t4_node_start a "$T4_WORK/node-a.json" "$T4_WORK/state-a"
t4_client --resume "$T4_WORK/session.json" --prompt 'turn after the SIGKILL' \
	--client-turn-id restart-3 --no-close
t4_journal_summary "$TIMELINE" | tail -12
grep -ciE "quarantin|corrupt|torn" "$T4_WORK/logs/a.log"
```

A restarted Node A does not give a resumed session its Workspace tools again, so
this drill sends no Workspace Turn after the restart (finding 6).

Expected output: the client reports `failed=false`. The journal ends with another
`replayEpochStarted` (`seq=25`), `turnAdmitted`, `sessionTransition ambiguous`,
`sessionTransition live`, the updates, and `turnCompleted completed` (`seq=36`).
The `grep` prints `0` and exits with status 1, as `grep -c` does when nothing
matches. Your shell may also print a `Killed` line for the Node A job. The kill came between Turns, so the journal had no torn
tail. A torn tail is truncated on open, and a corrupt committed prefix would
quarantine the Timeline as read-only. Either would appear in the Node A log.

## Drill 4: Kill a Node during a Turn

This drill checks what the client sees when a Node disappears in the middle of a
Turn, and that Gnostic never runs an admitted Turn twice.

1. Start both Nodes, attach the Workspace, and open a session:

   ```sh
   t4_node_stop a; t4_node_stop b
   rm -f "$T4_WORK/fixture/starts.log" "$T4_WORK/fixture/resumes.log" "$T4_WORK/fixture/prompts.log"
   t4_node_start b "$T4_WORK/node-b.json" "$T4_WORK/state-b"
   t4_node_start a "$T4_WORK/node-a.json" "$T4_WORK/state-a"
   t4_client --on-session "$T4_ATTACH_CMD" --prompt 'warm up' \
       --state-file "$T4_WORK/session.json" --no-close | tail -3
   TIMELINE=$(t4_session_timeline "$T4_WORK/session.json")
   ```

2. Send a Turn that stays open for 20 seconds, and kill Node A as soon as the
   Runtime has received the prompt. The Runtime appends one line to
   `prompts.log` for each prompt it receives, so a new line marks a Turn that is
   in flight:

   ```sh
   BEFORE=$(wc -l < "$T4_WORK/fixture/prompts.log" | tr -d ' ')
   t4_client --resume "$T4_WORK/session.json" --prompt 'long turn [fixture:wait]' \
       --client-turn-id kill-1 --timeout-ms 400000 --elapsed --no-close \
       > "$T4_WORK/kill-client.log" 2>&1 &
   CLIENT=$!
   t4_wait_prompts "$BEFORE" 30 && t4_node_kill a
   ```

   `t4_wait_prompts` fails with a message when the Runtime has not received the
   prompt within 30 seconds, and Node A is not killed then.

   `t4_node_kill a` sends `SIGKILL` to the `gnostic serve` process. The same
   command works on macOS and Linux, and the process gets no chance to shut down.
   To kill from another terminal, export the same `T4_WORK` there, source
   `t4.sh`, and run `t4_node_kill a`. Do not use `kill "$(cat "$T4_WORK/pids/a")"`
   or `pkill -f`: the system reuses a process ID after the process exits, and
   `pkill -f` also matches Node A of any other acceptance work directory. The
   helpers record the start time and the command line next to the PID, as
   `ps -o lstart= -o command= -p <pid>` prints them, and check both before every
   signal. A process that does not match is not signalled: the helper says so and
   clears the record. The Runtime child of Node A also ends when its stdio closes.

3. Look at the broker's view five seconds later, then wait for the client:

   ```sh
   sleep 5
   "$T4_BIN/gnostic" inspect list --config "$T4_WORK/node-b.json"
   wait $CLIENT; echo "client exit: $?"
   cat "$T4_WORK/kill-client.log"
   ```

   Expected output of `inspect list`: only Node B's Workspace. Node A's
   Timelines and Runtime instance are gone from discovery after five seconds.

   Expected output of the client:

   ```text
   client exit: 1
   [+  5s] initialize: protocolVersion=2
   [+  5s] session/resume: sessionId=<session-id> timeline=<timeline-id>
   [+  5s] session/prompt 1: "long turn [fixture:wait]" clientTurnID=kill-1
   [+  5s] update user_message: "long turn [fixture:wait]"
   [+  5s] update state_update: state=running
   [+  5s] update state_update: state=idle stopReason=error
   [+  5s] session/prompt 1: FAILED code=-32001 message="Provider <node-a-provider> went offline." data={"gnosticCode":"providerOffline"}
   [+  5s] summary: permissionRequests=0 failed=true elapsedSeconds=5
   ```

   The client learns of the loss within a second of the kill and not at a prompt
   timeout. The failure names the lost Node: `providerOffline`, with the provider
   ID of Node A. The Turn ends with `stopReason=error`. If the kill lands before
   Node A relays the first update, the client may print the failure without the
   `running` update. The five seconds before the first line are the start of
   `gnostic acp`, not a wait.

4. Restart Node A and retry the same Turn ID. Gnostic must not send the prompt
   again:

   ```sh
   t4_node_start a "$T4_WORK/node-a.json" "$T4_WORK/state-a"
   t4_client --resume "$T4_WORK/session.json" --prompt 'long turn [fixture:wait]' \
       --client-turn-id kill-1 --timeout-ms 30000 --no-close
   cat "$T4_WORK/fixture/prompts.log"
   ```

   Expected output:

   ```text
   session/prompt 1: "long turn [fixture:wait]" clientTurnID=kill-1
   update user_message: "long turn [fixture:wait]"
   update state_update: state=running
   update state_update: state=idle stopReason=error
   session/prompt 1: FAILED code=-32001 message="The Runtime did not confirm whether it inserted the prompt, and Gnostic does not send it again." data={"gnosticCode":"insertionUnknown"}
   summary: permissionRequests=0 failed=true elapsedSeconds=10
   ```

   `prompts.log` has two lines, the same as before the retry: the warm-up prompt
   and `long turn`. The Runtime did not receive `long turn` a second time. The
   retry returned the recorded state `insertionUnknown` and nothing else. A new
   Turn ID on the same Timeline works:

   ```sh
   t4_client --resume "$T4_WORK/session.json" --prompt 'after the failure' \
       --client-turn-id after-1 --timeout-ms 30000 --no-close | tail -3
   ```

   Expected output ends with `update state_update: state=idle stopReason=end_turn`.

5. Kill the Workspace Node while a Workspace tool call is in flight.

   Step 4 restarted Node A while Node B kept running. A restarted Node A does not
   restore the Workspace tools of a resumed session (finding 6, [#739](https://github.com/phynics/Gnostic/issues/739)), so attach the
   Workspace again first and check that a Workspace Turn works:

   ```sh
   T4_SESSION_TIMELINE_ID=$(t4_session_timeline "$T4_WORK/session.json") sh -c "$T4_ATTACH_CMD"
   t4_client --resume "$T4_WORK/session.json" --prompt 'read it [fixture:workspace-tool]' \
       --client-turn-id ws-check-1 --timeout-ms 60000 --no-close | tail -1
   ```

   Expected output: `attached workspace ...` and then `summary: permissionRequests=1
   failed=false elapsedSeconds=6`.

   A call to a healthy Node B finishes in milliseconds, so freeze Node B to hold
   the call open. The client waits six seconds before it answers its permission
   request (`--answer-delay-ms`), and `kill -STOP` stops Node B during that wait.
   After the approval, Node A forwards the call to a Node that cannot answer, so the
   call is in flight and stays there until something ends it. Kill Node B two
   seconds after the approval. `t4_kill_during_call` does the freeze, waits for the
   answer, waits two seconds, and kills Node B. Each wait ends after 30 seconds
   (set `T4_WAIT_SECONDS` to change it). If the client fails or crashes before it
   shows a permission request, or never answers, the function leaves Node B running
   or resumes it, prints why, and fails. If you interrupt it, it kills Node B
   rather than leave it frozen. Your shell may print a `Killed` line for the Node B
   job:

   ```sh
   rm -f "$T4_WORK/fixture/mcp.log"
   t4_client --resume "$T4_WORK/session.json" --prompt 'read it [fixture:workspace-tool]' --client-turn-id ws-kill-1 \
       --permission approve --answer-delay-ms 6000 --timeout-ms 120000 --elapsed --no-close > "$T4_WORK/ws-client.log" 2>&1 &
   CLIENT=$!
   t4_kill_during_call "$T4_WORK/ws-client.log" b 2
   wait $CLIENT; echo "client exit: $?"
   cat "$T4_WORK/ws-client.log"
   echo "--- the Runtime's gateway requests:"; cat "$T4_WORK/fixture/mcp.log"
   t4_journal_summary "$(t4_session_timeline "$T4_WORK/session.json")" | tail -3
   ```

   Expected output:

   ```text
   node b frozen (SIGSTOP) while the permission request waits
   node b killed (SIGKILL, pid <pid>) 2 seconds after the answer
   client exit: 1
   [+  5s] initialize: protocolVersion=2
   [+  5s] session/resume: sessionId=<session-id> timeline=<timeline-id>
   [+  5s] session/prompt 1: "read it [fixture:workspace-tool]" clientTurnID=ws-kill-1
   [+  5s] update user_message: "read it [fixture:workspace-tool]"
   [+  5s] update state_update: state=running
   [+  5s] permission request 1: "Run Workspace tool Read file" options=allow_once,reject_once
   [+ 11s] permission request 1: answered allow_once
   [+ 16s] update state_update: state=idle stopReason=error
   [+ 21s] session/prompt 1: FAILED code=-32001 message="The serve rejected the operation: acpAgentFailure (status 500)."
   [+ 21s] summary: permissionRequests=1 failed=true elapsedSeconds=21
   --- the Runtime's gateway requests:
   {"method":"initialize","outcome":"success","httpStatus":200}
   {"method":"tools/list","outcome":"success","httpStatus":200,"toolCount":2}
   {"method":"tools/call","outcome":"json-rpc-error","httpStatus":200,"errorCode":-32003,"errorCategory":"unclassified"}
    40 seq=40 turnAdmitted
    41 seq=41 permissionDecision approved
    42 seq=42 turnCompleted failed
   ```

   What each side saw. The Runtime's call hung for about 5 seconds after the
   approval, with no sign that Node B had gone. Then the Runtime received the
   JSON-RPC error -32003 as a normal tool failure (`mcp.log`, category
   `unclassified`). The fixture Runtime throws on any tool failure, so the Turn
   failed. The client got `state_update: idle stopReason=error` at that moment, and
   the final failure five seconds later as a generic `acpAgentFailure` (500). The
   journal holds `turnAdmitted`, the approval and `turnCompleted failed`, and
   nothing else for the Turn: no code, no reason, and no mention of the Workspace.
   Discovery no longer listed Node B's Workspace when the client finished, but
   nothing links that to the Turn. The same result appears when Node B stays
   frozen and is not killed. The step shows a clean terminal failure and no
   re-execution, but the client and the journal cannot tell a lost Workspace Node
   from a Runtime failure (finding 7, [#740](https://github.com/phynics/Gnostic/issues/740)). A real Runtime may handle the failed tool
   call and finish the Turn. With the fixture the Turn always fails.

6. Stop only the broker while a Turn is routed, with both Nodes up. Node B was
   killed in step 5, so start it first. The `[fixture:wait]` Turn stays open on the
   Runtime for 20 seconds. Stop the broker as soon as the Runtime has the prompt,
   and start it again ten seconds later:

   ```sh
   t4_node_start b "$T4_WORK/node-b.json" "$T4_WORK/state-b"
   sleep 3
   BEFORE=$(wc -l < "$T4_WORK/fixture/prompts.log" | tr -d ' ')
   t4_client --resume "$T4_WORK/session.json" --prompt 'broker turn [fixture:wait]' \
       --client-turn-id broker-1 --timeout-ms 150000 --elapsed --no-close > "$T4_WORK/broker-client.log" 2>&1 &
   CLIENT=$!
   t4_wait_prompts "$BEFORE" 30 && { t4_broker_stop; sleep 10; t4_broker_start; }
   wait $CLIENT; echo "client exit: $?"
   cat "$T4_WORK/broker-client.log"
   echo "prompts.log lines before and after: $BEFORE / $(wc -l < "$T4_WORK/fixture/prompts.log" | tr -d ' ')"
   ```

   Expected output:

   ```text
   broker stopped
   broker online at 127.0.0.1:1883 (pid <pid>)
   client exit: 1
   [+  5s] initialize: protocolVersion=2
   [+  5s] session/resume: sessionId=<session-id> timeline=<timeline-id>
   [+  5s] session/prompt 1: "broker turn [fixture:wait]" clientTurnID=broker-1
   [+  5s] update user_message: "broker turn [fixture:wait]"
   [+  5s] update state_update: state=running
   [+  5s] update state_update: state=idle stopReason=error
   [+  5s] session/prompt 1: FAILED code=-32001 message="Provider <node-a-provider> went offline." data={"gnosticCode":"providerOffline"}
   [+  5s] summary: permissionRequests=0 failed=true elapsedSeconds=5
   prompts.log lines before and after: <n> / <n+1>
   ```

   The client reports the same `providerOffline` failure as for a killed Node A,
   although Node A never stopped (the client's view is the one it has: its own
   connection to the broker ended). It gets no sign that the Turn may still run.
   Wait 25 seconds, then look at the Timeline and at discovery:

   ```sh
   sleep 25
   t4_journal_summary "$(t4_session_timeline "$T4_WORK/session.json")" | tail -5
   "$T4_BIN/gnostic" inspect list --config "$T4_WORK/node-a.json"
   pgrep -fa "gnostic serve" | wc -l
   ```

   Expected output:

   ```text
    43 seq=43 turnAdmitted
    44 seq=44 acpUpdate user_message
    45 seq=45 acpUpdate state_update
    46 seq=46 acpUpdate state_update
    47 seq=47 turnCompleted completed
   (no advertised objects)
   2
   ```

   Node A ran the Turn to `completed` and journaled it, although the client was told
   it failed. Both Nodes are still running, and neither has rejoined the restarted
   broker: discovery lists nothing and the logs hold no line about the broker. The
   Nodes did not rejoin in the three and a half minutes the proof run watched, and a
   two-second broker outage had the same result (finding 8, [#738](https://github.com/phynics/Gnostic/issues/738)). A retry of `broker-1`
   now fails with `Runtime instance ... was not discovered`. Restart both Nodes and
   retry:

   ```sh
   t4_node_stop a; t4_node_stop b
   t4_node_start b "$T4_WORK/node-b.json" "$T4_WORK/state-b"
   t4_node_start a "$T4_WORK/node-a.json" "$T4_WORK/state-a"
   t4_client --resume "$T4_WORK/session.json" --prompt 'broker turn [fixture:wait]' --client-turn-id broker-1 --timeout-ms 60000 --no-close
   echo "prompts.log lines: $(wc -l < "$T4_WORK/fixture/prompts.log" | tr -d ' ')"
   ```

   Expected output ends with the recorded Turn and `failed=false`:

   ```text
   session/prompt 1: "broker turn [fixture:wait]" clientTurnID=broker-1
   update user_message: "broker turn [fixture:wait]"
   update state_update: state=idle stopReason=end_turn
   session/prompt 1: accepted messageId=acp:user:broker-1
   summary: permissionRequests=0 failed=false elapsedSeconds=5
   prompts.log lines: <n+1>
   ```

   The retry returns the outcome that Node A recorded, `completed`, and `prompts.log`
   gains no line. Gnostic never sent the prompt a second time.

The mechanics of the drill pass. A Turn that loses Node A fails at once for the
client. The retry of the same Turn ID returns `insertionUnknown` for a Turn the
Runtime may not have inserted, and the recorded outcome for a Turn that completed.
`prompts.log` gains no line for any retry. The Timeline accepts a new Turn after
each restart.

The criterion of #552 T4 item 4 is not met. It asks for a clear distinction between
the disappearance of a remote Node, transport uncertainty, and a final Gnostic Turn
failure. What the client and the journal show today:

| What happened | What the client sees | What the journal holds |
| --- | --- | --- |
| Node A killed mid-Turn | `providerOffline` (-32001) at once | Not inspected in the proof run. The retry returns `insertionUnknown` |
| Broker stopped, both Nodes up, Turn completes | The same `providerOffline` (-32001), with `stopReason=error` | `turnCompleted completed` |
| Workspace Node killed mid-call | `acpAgentFailure` (500) after about 10 seconds | `turnCompleted failed`, no reason |
| Runtime fails by itself | `acpAgentFailure` (500) | `turnCompleted failed`, no reason |

The first two rows have the same client-side result for different causes, and the
second shows a failure for a Turn that completed. The third and fourth rows are the
same for the client and for the journal. Findings 6, 7, and 8 record these gaps.
Finding 2, which found a 300-second wait and a generic `callTimedOut`, did not
reproduce for the Node A kill.

## Drill 5: Send large content

This drill checks content above the 2 KiB Axoloty payload limit. Three limits
apply, and each one fails in a defined way.

Drill 4 left Node A and Node B running. Stop both and start them again, with
the `large` variant for Node A. Its Workspace tool reads `large.txt`, which is
6,200 bytes. `t4_node_start` refuses to start a Node whose recorded process is
still alive (the record holds the start time and command line, so a recycled process
ID is not mistaken for the Node), and a Node that you forgot to stop cannot run twice:

```sh
t4_node_stop a; t4_node_stop b
rm -f "$T4_WORK/fixture/starts.log" "$T4_WORK/fixture/resumes.log" "$T4_WORK/fixture/prompts.log"
t4_node_start b "$T4_WORK/node-b.json" "$T4_WORK/state-b"
t4_node_start a "$T4_WORK/node-a.large.json" "$T4_WORK/state-a"
PADDING=$(node -e 'process.stdout.write("p".repeat(1300))')
t4_client --on-session "$T4_ATTACH_CMD" --prompt "[fixture:workspace-tool] $PADDING" --text-totals \
	--print-max 60 --state-file "$T4_WORK/session.json" --no-close
```

`--text-totals` adds a line with the number of bytes of reply text that the client
received. Expected output. The first update is the prompt echo. The reply arrives in
several chunks, and the last chunk ends with the marker that the Workspace wrote:

```text
session/prompt 1: "[fixture:workspace-tool] ppppppppppppppppppppppppppppppppppp…(1325 chars)"
update user_message: "[fixture:workspace-tool] ppppppppppppppppppppppppppppppppppp…(1325 chars)"
update state_update: state=running
permission request 1: "Run Workspace tool Read file" options=allow_once,reject_once
permission request 1: answered allow_once
update agent_message_chunk: "fixture "
update agent_message_chunk: "reply: [fixture:workspace-tool] pppppppppppppppppppppppppppp…(800 chars)"
update agent_message_chunk: "pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp…(808 chars)"
update agent_message_chunk: "xxxxxxxxxxxxx\\nline 010 xxxxxxxxxxxxxxxxxxxxx\\nline 011 xxxx…(826 chars)"
update agent_message_chunk: "xxxxx\\n[truncated: showing the first 1070 of 6200 bytes]"
update tool_call_update: Inspect fixture input status=pending
update tool_call_update: Inspect fixture input status=completed
update state_update: state=idle stopReason=end_turn
session/prompt 1: accepted messageId=<message-id>
session/prompt 1: agent text 2463 bytes in 5 chunks
summary: permissionRequests=1 failed=false elapsedSeconds=7
```

The chunk count and sizes can differ by a few bytes, because the split follows the
byte limit of the wire. Compare the live text with the journal:

```sh
t4_journal_text "$(t4_session_timeline "$T4_WORK/session.json")"
```

Expected output:

```text
journal seq=9 agent_message_chunk 8 bytes
journal seq=10 agent_message_chunk 2455 bytes
journal: agent text 2463 bytes in 2 chunks
```

The live client received all 2,463 bytes, in five chunks, and the journal holds the
same 2,463 bytes in two records. A Runtime message longer than the wire limit is
split on the live path and kept whole in the journal. Nothing is cut.

Then send a prompt over the 1,400-byte limit:

```sh
t4_client --resume "$T4_WORK/session.json" \
	--prompt "$(node -e 'process.stdout.write("q".repeat(3000))')" \
	--client-turn-id big-1 --print-max 40 --timeout-ms 30000 --no-close
cat "$T4_WORK/fixture/prompts.log"
```

Expected output:

```text
session/prompt 1: "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq…(3000 chars)" clientTurnID=big-1
update user_message: "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq…(3000 chars)"
update state_update: state=running
update state_update: state=idle stopReason=error
session/prompt 1: FAILED code=-32602 message="The prompt exceeds the maximum size the …(80 chars)" data={"gnosticCode":"promptTooLarge"}
```

`prompts.log` shows one line for the whole drill: the first prompt. The oversized
prompt never reached the Runtime. Check that the Timeline still works:

```sh
t4_client --resume "$T4_WORK/session.json" --prompt 'still alive' --timeout-ms 30000 | tail -3
```

Expected output ends with `summary: permissionRequests=0 failed=false`.

What the drill shows:

| Content | Limit | Behavior |
| --- | --- | --- |
| A prompt | 1,400 bytes | Gnostic rejects a larger prompt with `promptTooLarge` (-32602) before it admits or sends the Turn. It does not truncate. |
| A Workspace tool result | 1,200 bytes | The `filesystem` Workspace cuts its output and ends it with `[truncated: showing the first 1070 of 6200 bytes]`. The model sees the marker. |
| A Runtime update | About 800 bytes of text per live update | Node A journals the whole update (2,455 bytes here). The live stream splits the text into several updates of about 800 bytes each, and the client receives all of it. See finding 3. |

The Timeline journal is not subject to the wire limits, because Node A writes it
to disk on the owning Node.

The drill passes when a larger prompt is rejected by name and never reaches the
Runtime, a long tool result ends in a `[truncated: ...]` marker, and the client
receives as many bytes of the Runtime update as the journal holds. Finding 3, which
found that the live update lost text without a marker, did not reproduce.

## Repeat Drill 1 with the reference Runtime

Run the journey again with the standalone reference Runtime, which Node A
supervises over ACP v2 on stdio. Its scripted model needs no provider. Do this
after Drill 5, because it renders a new work directory.

1. Stop the processes from the earlier drills and render a work directory for the
   reference Runtime. `--extra-timelines 8` adds eight Timelines to the manifest of
   Node A, so that Node A loads nine Timelines at start. That is more than twice the
   core count of the proof machine:

   ```sh
   t4_node_stop a; t4_node_stop b; t4_broker_stop
   export T4_WORK=$(mktemp -d)
   eval "$(node "$T4_FIXTURES/render.mjs" --work "$T4_WORK" --repo "$REPO" --runtime reference --pk-runtime "$T4_BIN/gnostic-pk-runtime" --extra-timelines 8 --print-env)"
   . "$T4_FIXTURES/t4.sh"
   t4_broker_start
   t4_node_start b "$T4_WORK/node-b.json" "$T4_WORK/state-b"
   t4_node_start a "$T4_WORK/node-a.json" "$T4_WORK/state-a"
   ```

2. Send a plain prompt and a prompt that makes the scripted model call the
   gateway tool:

   ```sh
   t4_client --on-session "$T4_ATTACH_CMD" --prompt 'hello reference' \
       --prompt 'call the gateway [fixture:gateway-tool]' --print-max 300
   ```

   Expected output, abridged:

   ```text
   update agent_message_chunk: "scripted response: hello reference"
   update state_update: state=idle stopReason=end_turn
   permission request 1: "Run Workspace tool Read file" options=allow_once,reject_once
   permission request 1: answered allow_once
   update agent_message_chunk: "scripted response after Gnostic gateway tool: Error: Failed to execute the tool: Only the 'path' argument is accepted.\\nHow to fix: Read the error message above, adjust your arguments accordingly, and retry; if it keeps failing, try a different tool or approach."
   update state_update: state=idle stopReason=end_turn
   summary: permissionRequests=1 failed=false elapsedSeconds=7
   ```

   The scripted model always calls the tool with `{"query":"fixture"}`. The
   `filesystem` Workspace validates its arguments and rejects that call as a
   failed tool result. The result proves the path: the reference Runtime, the
   gateway on Node A, the permission request to the client, and the `read_file`
   tool on Node B. Only a real model can read `note.txt` here. The Node A log
   then holds `error com.positronickit.tool-router` lines for the rejected call.
   That is the expected failed tool result and not a Node fault.

3. Check that the Node stays responsive with many Timelines. Open five more
   sessions on the reference Runtime and count the Timelines:

   ```sh
   for count in 1 2 3 4 5; do
       t4_client --on-session "$T4_ATTACH_CMD" --prompt 'call the gateway [fixture:gateway-tool]' --no-close \
           | grep -E "FAILED|TIMED OUT|summary"
   done
   "$T4_BIN/gnostic" inspect list --config "$T4_WORK/node-a.json" | grep -c Timeline
   ```

   Expected output: five lines `summary: permissionRequests=1 failed=false
   elapsedSeconds=7`, then `15`. That is nine Timelines from the manifest, the
   session from step 2, and the five new ones. On the 4-core proof machine, Node
   A came online in about one second with nine Timelines and completed every Turn.

To run the reference Runtime with a live provider (not run), remove the scripted
mode and add the provider key as a secret. `set-secret` reads the key from
standard input:

```sh
"$T4_BIN/gnostic" config backend set "$T4_RUNTIME_ID" env '{"GNOSTIC_PK_STATE_DIR":"'"$T4_WORK"'/pk-state","GNOSTIC_PK_MODEL":"<model>"}' --config "$T4_WORK/node-a.json"
printf '%s' "$PROVIDER_API_KEY" | "$T4_BIN/gnostic" config backend set-secret "$T4_RUNTIME_ID" env-secret.GNOSTIC_PK_API_KEY --config "$T4_WORK/node-a.json"
```

Then restart Node A and send a prompt such as `list the files in the workspace`.

## Clean up

```sh
t4_node_stop a; t4_node_stop b; t4_broker_stop
rm -rf "$T4_WORK"
```

If a process does not stop, run `t4_node_kill <name>`. It checks the recorded start
time and command line first, so it never signals a process that is not yours.

## Record the result

Paste these into #552 under T4:

- `git rev-parse HEAD` and `"$T4_BIN/gnostic" --version`.
- The operating system, `uname -m`, and the core count.
- Whether Node A stayed responsive with more live sessions than cores (Drill 1
  step 4).
- The output of each drill, and which findings you reproduced.
- Axoloty and MQTT versions from `Package.resolved`, and the MQTT `coaty/3`
  profile the Nodes used.
- The Runtime: fixture, reference with a scripted model, or reference with a live
  provider and the model name.

## Findings from the proof runs

Four findings came out of the first proof runs of this runbook. The Linux runs on
`7e2947f` re-checked each one and found four more. The table gives the state on
that commit. No macOS run exists, so every finding is open for macOS until someone
runs it there.

| Finding | Earlier proof run | Linux, `7e2947f` |
| --- | --- | --- |
| 1. A Node stalls when blocked threads fill the Swift concurrency pool | Critical on 4 cores | Not reproduced |
| 2. A Node killed during a Turn fails the client only at the prompt timeout | Important | Not reproduced |
| 3. The live stream cuts a Runtime message to 800 bytes without a marker | Important | Not reproduced |
| 4. `gnostic serve` does not flush `gnostic serve online` to a file | Minor | Reproduced |
| 5. `make shell` does not open a shell | | Reproduced (repository tooling) |
| 6. A restarted Node A loses the Workspace tools of a resumed session | | New, Important. Fix tracked in [#739](https://github.com/phynics/Gnostic/issues/739), before rc.1 |
| 7. The client and the journal cannot tell a lost Workspace Node from a Runtime failure | | New, Important. Tracked in [#740](https://github.com/phynics/Gnostic/issues/740) |
| 8. Nodes never rejoin a restarted broker, and the client cannot tell broker loss from Node loss | | New, Critical for operation. Fix tracked in [#738](https://github.com/phynics/Gnostic/issues/738), before rc.1 |

1. **A Node stalls when blocked threads fill the Swift concurrency pool
   (resolved by #695 and #711).** The earlier runs stalled on a 4-core host: a
   manifest with two Timelines did not come online, the first Turn on a
   `session/new` Timeline never reached the Runtime, and `workspace.attach` timed
   out with 504. The runs on `7e2947f` used no workaround on a 4-core machine.
   Node A loaded nine manifest Timelines in about one second. Seven live sessions
   with Workspace gateways, more than the two that stalled the earlier build, each
   attached the Workspace and completed a Turn, with the fixture Runtime and with
   the reference Runtime. The proof did not run the earlier commit again for
   comparison. The stall itself comes from the first proof run and from the
   regression test that #695 added. The workaround flag in the fixtures is removed.

2. **A Node killed during a Turn failed the client only at the prompt timeout
   (resolved for the Node A kill).** The earlier client waited about 300 seconds
   and got a generic `callTimedOut` (504). On `7e2947f` the client got
   `providerOffline` (-32001) within a second of the kill, with the
   `stopReason=error` update. After a restart, the retry of the same Turn ID
   returns `insertionUnknown` and the prompt is not sent again. The other loss
   cases are findings 7 and 8.

3. **The live update stream cut a Runtime message to 800 bytes without a marker
   (resolved by #706).** On `7e2947f` the live client received all 2,463 bytes of
   a reply, in five updates, and the journal held the same 2,463 bytes.

4. **`gnostic serve` does not flush its `gnostic serve online` line when its
   output is a file (Minor, open).** The line appears in the log only when the
   Node exits. `Scripts/runner-smoke.sh` works around it with `stdbuf`, which
   macOS lacks. `t4.sh` waits for the `advertised objects` log line instead.

5. **`make shell` does not open a shell (Minor, repository tooling).**
   `.devcontainer/lock.sh` and `.devcontainer/run-container.sh` each run their
   command in a background job. A background job of a non-interactive shell has no
   stdin and no terminal, so `bash` exits at once. The README repeats the command
   in its flaky-test recipe. This runbook uses `container-shell.sh` instead. The
   fix is to keep stdin and add `-it` when stdin is a terminal, in both scripts.

6. **A restarted Node A loses the Workspace tools of a resumed session
   (Important, product).** Reproduction: with both Nodes running and a session
   that has the Workspace attached, stop and start Node A (Node B keeps running),
   then resume the session and send `read it [fixture:workspace-tool]`. The
   fixture Runtime sees zero tools and fails the Turn with `acpAgentFailure` (500).
   With the reference Runtime, the model gets `The requested tool 'call_tool' could
   not be found` and no permission request appears. The journal still holds
   `workspaceAttached network`, and `inspect list` still shows the Workspace. The
   Workspace stays unusable for that session until you attach it again with
   `gnostic-workspace-attach`, or restart Node B. Waiting did not help (tested up to
   20 seconds). It persists across further Turns once re-attached. The owner will
   fix this before rc.1 in [#739](https://github.com/phynics/Gnostic/issues/739).

7. **The client and the journal cannot tell a lost Workspace Node from a Runtime
   failure (Important, product).** Step 5 of Drill 4: a Workspace call in flight at
   the kill ends after about 5 seconds with the JSON-RPC error -32003 for the
   Runtime, and the Turn fails with `acpAgentFailure` (500). The journal holds
   `turnCompleted failed` with no reason. Nothing in the Turn names the Workspace. Tracked in
   [#740](https://github.com/phynics/Gnostic/issues/740).

8. **Nodes never rejoin a restarted broker, and the client cannot tell a broker loss
   from a Node loss (Critical for operation, product).** Reproduction: start the
   broker and both Nodes, run `t4_broker_stop; sleep 2; t4_broker_start`, then
   `gnostic inspect list`. It prints `(no advertised objects)`, forever (watched for
   three and a half minutes), although both `gnostic serve` processes are still
   running and write no log line. Only a restart of both Nodes recovers. A Turn that
   is running when the broker stops completes on Node A and is journaled
   `completed`, while the client has already been told `providerOffline` and
   `stopReason=error`. The failure code is the one for a killed Node, so the client
   cannot tell the two apart, and it does not learn that the Turn may still
   finish. The retry by Turn ID, after the Nodes restart, returns the recorded
   `completed` outcome, and the Runtime gets no second prompt. The owner will fix the
   rejoin before rc.1 in [#738](https://github.com/phynics/Gnostic/issues/738).
