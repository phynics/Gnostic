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

The commands and outputs below come from a release build of `main` at `b361b6b`
with the fixtures from this change applied. Linux outputs were captured on
2026-11-01 in the development container (x86_64, 4 cores). Nobody has run this
runbook on macOS or with a live model provider.

| Part | Linux, dev container | macOS | Live provider |
| --- | --- | --- | --- |
| Release build of `gnostic`, `gnostic-pk-runtime`, `gnostic-workspace-attach` | Run | Not run | Not applicable |
| Broker, two Nodes, Workspace attach | Run | Not run | Not applicable |
| Drill 1 with the fixture Runtime | Run | Not run | Not applicable |
| Drill 1 with the reference Runtime (scripted model) | Run | Not run | Not run |
| Drills 2 to 5 | Run | Not run | Not applicable |

All Linux outputs were captured with `--free-pool-thread`. The proof runs also
produced four findings, listed in
[Findings from the proof runs](#findings-from-the-proof-runs). Read finding 1
before you start: on a machine with 4 or fewer cores, a Node can stall.

## Before you start

You need these tools. The Linux column lists what the development container
already provides.

| Tool | Linux | macOS |
| --- | --- | --- |
| Swift 6.4.0 toolchain | In the container image `swift:6.4.0-noble` | Install Swift 6.4.0 from swift.org. `Package.swift` declares `swift-tools-version: 6.4` and macOS 26. Not run. |
| Container runtime | `podman` or `docker`, for `make shell` | Not needed |
| Node.js 22 | In the container (22.18.0) | `brew install node@22`. Not run. |
| Mosquitto broker and `mosquitto_pub` | In the container | `brew install mosquitto`. Not run. |
| Git | From your distribution | Xcode command line tools |

Run `swift --version` and confirm that it prints `Swift version 6.4.0`.

## Build the release binaries

You need three executables: `gnostic`, `gnostic-pk-runtime`, and
`gnostic-workspace-attach`. A release build from a cold cache took about 30
minutes on a loaded 4-core machine.

On Linux, build inside the container. The container stops after
`CONTAINER_TIMEOUT` seconds, 3600 by default, so build in one session and run the
drills in another.

1. Resolve the dependencies and open the container:

   ```sh
   make resolve
   make shell
   ```

2. In the container shell, build the three products:

   ```sh
   FLAGS="--cache-path /workspace/.swiftpm-cache --disable-automatic-resolution --build-system native -c release"
   swift build $FLAGS --product gnostic
   swift build $FLAGS --product gnostic-pk-runtime
   swift build $FLAGS --product gnostic-workspace-attach
   swift build $FLAGS --show-bin-path
   ```

   The last command prints the directory that holds the binaries. Keep it. On
   Linux x86_64 it is `/workspace/.build/x86_64-unknown-linux-gnu/release`.

On macOS (not run), build natively from the repository root:

```sh
swift build -c release --product gnostic
swift build -c release --product gnostic-pk-runtime
swift build -c release --product gnostic-workspace-attach
swift build -c release --show-bin-path
```

## Prepare the shell

Run the rest of this runbook in one shell. On Linux, open a new container shell
with `CONTAINER_TIMEOUT=7200 make shell`. Every Node and the broker run in the
background of that shell, and the helpers write their logs under `$T4_WORK/logs`.

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

4. Render the manifests and load the helpers. If the machine has 4 or fewer
   cores, add `--free-pool-thread` to the first command (see finding 1). If
   another process already listens on port 1883, add `--broker-port 1884`:

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
broker online at 127.0.0.1:1883 (pid 38)
node b online (pid 45)
node a online (pid 60)
```

`t4_node_start` waits for the line `advertised objects` in the Node's log. It does
not wait for `gnostic serve online`, because `gnostic serve` buffers that line
when its output goes to a file.

Confirm that both Nodes are visible on the broker:

```sh
"$T4_BIN/gnostic" inspect list --config "$T4_WORK/node-a.json"
```

Expected output, one object per line, in any order:

```text
me.atkn.gnostic.Workspace  <workspace-id>  <node-b-provider>  <T4_WORK>/workspace-root  available uri=<T4_WORK>/workspace-root tools=[list_directory,read_file]
me.atkn.gnostic.Timeline  <timeline-id>  <node-a-provider>  T4 default Timeline
me.atkn.gnostic.RuntimeInstance  <runtime-id>  <node-a-provider>  gnostic-deterministic-acp-fixture
```

## Attach the Workspace to a Timeline

`gnostic` has no command that attaches a Workspace to a running Timeline. Two
mechanisms exist, and only one fits this journey.

- **The `attachments` manifest field.** Set `scope` to `network` and `uri` to the
  Workspace's advertised `uri`. `gnostic config timeline attach-workspace
  <timeline-id> <workspace-id> --network <uri>` writes it. Node A then advertises
  the Workspace in the Timeline's `attachedWorkspaceIDs`, and the Workspace
  resolves lazily. This works only for a Timeline that is listed in the
  manifest. `gnostic acp` does not use such a Timeline. Each `session/new`
  creates a new Timeline that no manifest lists. The proof run showed that Node A
  advertises the attachment. It did not exercise a tool call through it.
- **A client call.** The `workspace.attach` operation attaches a discovered
  Workspace to any Timeline, including one that `session/new` just created. No
  `gnostic` command makes this call, so this change adds the executable
  `gnostic-workspace-attach`. It is a short consumer of the public
  `GnosticClient` API (85 lines) that makes the same call as the two-Node
  integration test.

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
   -rw------- 1 <user> <group> 6255 <date> <T4_WORK>/state-a/timeline-journals/<node-a-id>/timeline-<timeline-id>-v1.jsonl
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

3. Check that Node B holds no journal:

   ```sh
   ls "$T4_WORK/state-b"
   ```

   Expected output: nothing. The Timeline lives on Node A, and Node B only
   serves the Workspace.

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
[+  6s] permission request 1: "Inspect fixture input" options=allow_once,reject_once
[+  6s] permission request 1: answered allow_once
[+  6s] update state_update: state=idle stopReason=end_turn
Runtime received: {"optionId":"allow-once","outcome":"selected"}
  7 seq=7 permissionDecision approved
 13 seq=13 turnCompleted completed
```

Expected output for `deny`:

```text
[+  6s] permission request 1: "Inspect fixture input" options=allow_once,reject_once
[+  6s] permission request 1: answered reject_once
[+  6s] update state_update: state=idle stopReason=end_turn
Runtime received: {"optionId":"reject-once","outcome":"selected"}
  7 seq=7 permissionDecision denied
 13 seq=13 turnCompleted completed
```

Expected output for `unanswered`. The client never answers. After 120 seconds
Node A stops waiting:

```text
[+  6s] permission request 1: "Inspect fixture input" options=allow_once,reject_once
[+  6s] permission request 1: not answering (waiting from t=6s)
[+126s] update agent_message_chunk: "fixture "
[+126s] update agent_message_chunk: "reply: permission drill"
[+126s] update state_update: state=idle stopReason=end_turn
[+126s] summary: permissionRequests=1 failed=false elapsedSeconds=126
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
update state_update: state=idle stopReason=end_turn
session/prompt 1: accepted messageId=acp:user:restart-2
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
and one `session/resume` request for the same Runtime session.

Retry the first Turn by its ID. Node A returns the recorded Turn and does not send
a second prompt:

```sh
t4_client --resume "$T4_WORK/session.json" --prompt 'first turn before the restart' \
	--client-turn-id restart-1 --no-close
cat "$T4_WORK/fixture/prompts.log"
```

Expected output of `prompts.log`: two lines, one per prompt the Runtime ever
received (`restart-1` and `restart-2`). The retry added none.

Now repeat the recovery after an abrupt loss. Kill Node A, restart it, and resume:

```sh
t4_node_kill a
t4_node_start a "$T4_WORK/node-a.json" "$T4_WORK/state-a"
t4_client --resume "$T4_WORK/session.json" --prompt 'turn after the SIGKILL' \
	--client-turn-id restart-3 --no-close
t4_journal_summary "$TIMELINE" | tail -12
grep -ciE "quarantin|corrupt|torn" "$T4_WORK/logs/a.log"
```

Expected output: another `replayEpochStarted`, `sessionTransition ambiguous`,
`sessionTransition live`, and `turnCompleted completed` at the end of the journal.
The `grep` prints `0`. The kill came between Turns, so the journal had no torn
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
   until [ "$(wc -l < "$T4_WORK/fixture/prompts.log" | tr -d ' ')" -gt "$BEFORE" ]; do sleep 0.2; done
   t4_node_kill a
   ```

   `t4_node_kill a` sends `SIGKILL` to the `gnostic serve` process. The same
   command works on macOS and Linux, and the process gets no chance to shut down.
   To kill from another terminal, run `pkill -KILL -f "gnostic serve --config
   .*node-a.json"`. The Runtime child of Node A also ends when its stdio closes.

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
   [+305s] update user_message: "long turn [fixture:wait]"
   [+305s] update state_update: state=running
   [+305s] update state_update: state=idle stopReason=error
   [+310s] session/prompt 1: FAILED code=-32001 message="The serve rejected the operation: callTimedOut (status 504)."
   [+310s] summary: permissionRequests=0 failed=true elapsedSeconds=310
   ```

   The times vary by a few seconds. The client receives nothing for five minutes.
   In this run the kill landed before Node A relayed any update, so the client
   learned of the Turn and its failure at the same moment. If the kill lands
   after the `running` update, the client prints that update at once and then
   waits the same time. The terminal failure arrives at the 300-second prompt
   timeout of `gnostic acp` and carries a generic `callTimedOut` with status 504.
   It does not tell you that the Node vanished, although discovery knew five
   seconds after the kill. See finding 2.

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

5. Kill the Workspace Node. With Node A running, kill Node B, wait five seconds,
   and send a Workspace Turn:

   ```sh
   t4_node_kill b
   sleep 5
   t4_client --resume "$T4_WORK/session.json" --prompt 'read it [fixture:workspace-tool]' \
   	--client-turn-id ws-after-b-1 --timeout-ms 60000 --no-close
   ```

   Expected output ends with:

   ```text
   update state_update: state=running
   update state_update: state=idle stopReason=error
   session/prompt 1: FAILED code=-32001 message="The serve rejected the operation: acpAgentFailure (status 500)."
   ```

   Node A no longer advertises the Workspace tools, so the fixture Runtime
   fails its own check that two tools exist. A real Runtime would see an empty
   tool list instead. The Turn ends in a clean failure and Node A stays up.

The drill passes when four things hold. The killed Turn ends in a terminal
failure for the client. The retry of the same Turn ID returns `insertionUnknown`.
`prompts.log` gains no line for the retry. The Timeline accepts a new Turn after
the restart. T4 also asks for a clear distinction between a vanished Node,
transport uncertainty, and a final Turn failure. The first failure does not make
that distinction today, so record finding 2 as open when you report the drill.

## Drill 5: Send large content

This drill checks content above the 2 KiB Axoloty payload limit. Three limits
apply, and each one fails in a defined way.

Drill 4 left Node B stopped. Start it again, then restart Node A with the `large`
variant. Its Workspace tool reads `large.txt`, which is 6,200 bytes:

```sh
t4_node_stop a
rm -f "$T4_WORK/fixture/starts.log" "$T4_WORK/fixture/resumes.log" "$T4_WORK/fixture/prompts.log"
t4_node_start b "$T4_WORK/node-b.json" "$T4_WORK/state-b"
t4_node_start a "$T4_WORK/node-a.large.json" "$T4_WORK/state-a"
PADDING=$(node -e 'process.stdout.write("p".repeat(1300))')
t4_client --on-session "$T4_ATTACH_CMD" --prompt "[fixture:workspace-tool] $PADDING" \
	--print-max 60 --state-file "$T4_WORK/session.json" --no-close
```

Expected output:

```text
session/prompt 1: "[fixture:workspace-tool] ppppppppppppppppppppppppppppppppppp…(1325 chars)"
update user_message: "[fixture:workspace-tool] ppppppppppppppppppppppppppppppppppp…(1325 chars)"
permission request 1: "Run Workspace tool Read file" options=allow_once,reject_once
permission request 1: answered allow_once
update agent_message_chunk: "reply: [fixture:workspace-tool] pppppppppppppppppppppppppppp…(800 chars)"
update state_update: state=idle stopReason=end_turn
```

Now compare the live update with the journal:

```sh
TIMELINE=$(t4_session_timeline "$T4_WORK/session.json")
node -e '
	for (const line of require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n")) {
		const record = JSON.parse(line.slice(line.indexOf("{")));
		const update = record.payload.acpUpdate?.update?.update ?? record.payload.acpUpdate?.update;
		const text = update?.content?.text;
		if (update?.sessionUpdate === "agent_message_chunk" && text) console.log("journal: agent_message_chunk", Buffer.byteLength(text), "bytes, ends:", JSON.stringify(text.slice(-60)));
	}' "$(t4_journal "$TIMELINE")"
```

Expected output:

```text
journal: agent_message_chunk 8 bytes, ends: "fixture "
journal: agent_message_chunk 2455 bytes, ends: "35 xxxxxxx\n[truncated: showing the first 1070 of 6200 bytes]"
```

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
| A Runtime update | 800 bytes of text per live update | Node A journals the whole update (2,455 bytes here). The live stream to the client cuts the text to 800 bytes and adds no marker. See finding 3. |

The Timeline journal is not subject to the wire limits, because Node A writes it
to disk on the owning Node.

The drill passes when a larger prompt is rejected by name and never reaches the
Runtime, a long tool result ends in a `[truncated: ...]` marker, and the journal
holds the whole Runtime update. Record finding 3 as open when you report the
drill: the live update loses text without a marker.

## Repeat Drill 1 with the reference Runtime

Run the journey again with the standalone reference Runtime, which Node A
supervises over ACP v2 on stdio. Its scripted model needs no provider. Do this
after Drill 5, because it renders a new work directory.

1. Stop the processes from the earlier drills and render a work directory for the
   reference Runtime:

   ```sh
   t4_node_stop a; t4_node_stop b; t4_broker_stop
   export T4_WORK=$(mktemp -d)
   eval "$(node "$T4_FIXTURES/render.mjs" --work "$T4_WORK" --repo "$REPO" --runtime reference --pk-runtime "$T4_BIN/gnostic-pk-runtime" --print-env)"
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
   update agent_message_chunk: "scripted response after Gnostic gateway tool: Error: Failed to execute the tool: Only the 'path' argument is accepted.\\nHow to fix: ..."
   update state_update: state=idle stopReason=end_turn
   summary: permissionRequests=1 failed=false
   ```

   The scripted model always calls the tool with `{"query":"fixture"}`. The
   `filesystem` Workspace validates its arguments and rejects that call as a
   failed tool result. The result proves the path: the reference Runtime, the
   gateway on Node A, the permission request to the client, and the `read_file`
   tool on Node B. Only a real model can read `note.txt` here.

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

If a process does not stop, `kill -KILL "$(cat "$T4_WORK/pids/<name>")"`.

## Record the result

Paste these into #552 under T4:

- `git rev-parse HEAD` and `"$T4_BIN/gnostic" --version`.
- The operating system, `uname -m`, and the core count.
- Whether you used `--free-pool-thread`.
- The output of each drill, and which findings you reproduced.
- Axoloty and MQTT versions from `Package.resolved`, and the MQTT `coaty/3`
  profile the Nodes used.
- The Runtime: fixture, reference with a scripted model, or reference with a live
  provider and the model name.

## Findings from the proof runs

Four findings came out of writing this runbook. Finding 1 adds a flag to the
commands, and the others change what you should expect. The Linux proof ran
against the commit named at the top. None of the findings has an issue yet.

1. **A Node stalls when its blocked threads fill the Swift concurrency pool
   (Critical on a machine with 4 or fewer cores).**
   On a 4-core host:
   - A manifest with two Timelines does not come online within 20 seconds.
   - The first Turn on a Timeline that `session/new` created never reaches the
     Runtime. A capture of the Runtime's stdin shows `initialize`, one
     `session/new`, and `session/list`, and then nothing.
   - `workspace.attach` to any Timeline, made while a `session/new` Timeline
     exists, fails with `callTimedOut` (504), and Node A then disappears from
     discovery.
   - The same flows pass when the Runtime does not advertise MCP support, when
     the stderr of the Runtime is closed (`--free-pool-thread`), and when a
     single Timeline exists.
   - The release and the debug build behave the same.

   The likely cause: the Runtime child pins two pool threads (a blocking read of
   its stdout in `ACPProcessStdioTransport.swift` and a blocking read of its
   stderr in `ACPAscendantBackend.swift`), and each Workspace MCP gateway pins one
   more in a blocking `accept()` (`WorkspaceMCPGateway.swift`). With four cores,
   two gateways use the whole pool. The proof run did not confirm this with a
   stack trace, because `ptrace` is blocked in the container. If the cause holds,
   each extra Timeline with a session costs one more thread, so a Node would
   stall at about `cores - 2` Timelines on any machine. `--free-pool-thread` wraps the Runtime
   in `sh -c 'exec 2>/dev/null; exec "$0" "$@"'`, which ends the stderr reader at
   once and frees one thread. It hides the symptom on four cores and is not a fix.

2. **A Node killed during a Turn fails the client only at the prompt timeout
   (Important).** The client waits about 300 seconds and gets a generic
   `callTimedOut` (504). Discovery drops the Node within five seconds. #552 T4
   asks for a clear distinction between Node disappearance, transport
   uncertainty, and a Turn failure. After a restart the retry does return the
   structured `insertionUnknown`, and the prompt is never re-sent.

3. **The live update stream cuts a Runtime message to 800 bytes without a marker
   (Important).** `AscendantTurnUpdateStore.bounded` limits the text of each
   update. The journal keeps the full text, so the loss is in what the live client sees.

4. **`gnostic serve` does not flush its `gnostic serve online` line when its
   output is a file (Minor).** `Scripts/runner-smoke.sh` works around it with
   `stdbuf`, which macOS lacks. `t4.sh` waits for the `advertised objects` log
   line instead.
