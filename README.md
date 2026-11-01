# Gnostic

Gnostic hosts Runtime processes and exposes Timeline orchestration over
Axoloty. Every Runtime uses ACP v2 over stdio. The standalone reference Runtime
uses PositronicKit privately; the host does not. The 0.5.0 line is in
development
([#551](https://github.com/phynics/Gnostic/issues/551)).

The [0.5.0 compatibility declaration](Documentation/Compatibility/0.5.0.md)
records what changes from 0.4.2. It is a source-breaking minor for Swift
consumers: public types moved into new library products. It is wire-breaking
from 0.4.2 and migrates operator configuration without converting execution
history. The
[0.4.2 compatibility declaration](Documentation/Compatibility/0.4.2.md)
records the load-time cancellation-shield fix. The
[0.4.1 declaration](Documentation/Compatibility/0.4.1.md) records the
deployment-target fix. The
[0.4.0 declaration](Documentation/Compatibility/0.4.0.md) lists the public
consumer clients. The [0.3.0 declaration](Documentation/Compatibility/0.3.0.md)
remains authoritative for the protocol, manifest, and intentional 0.2 breaks.
The pre-reset configuration migrations were retired after 0.4 (ADR 0003
amendment): migrate an older file with Gnostic 0.4 first.

## Start a Node

Build the package with the repository targets:

```sh
make resolve
make build
```

Create and validate a Node manifest:

```sh
gnostic config init
gnostic config validate
gnostic config show --json
```

The default manifest lives at `~/.gnostic/config.json`. Use `--config PATH` or
`GNOSTIC_CONFIG` to select another file. `GNOSTIC_MQTT_HOST`,
`GNOSTIC_MQTT_PORT`, and `GNOSTIC_MQTT_NAMESPACE` override the broker values
when a command reads the manifest.

Configure an ACP Runtime command and its arguments, then start the Node. The
Runtime owns its model and provider selection:

```sh
gnostic config backend set <ASCENDANT_UUID> command /path/to/acp-runtime
gnostic config backend set <ASCENDANT_UUID> args '["--stdio"]'
gnostic config validate
gnostic serve
```

Use `--host`, `--port`, and `--namespace` for one serve process without
changing the manifest. Use `--approve-mode deny` to reject Workspace
attachment requests.

## Manage resources

The CLI manages Ascendants, Timelines, and Workspaces in the manifest. Resource
updates preserve existing IDs and validate references before writing:

```sh
gnostic config ascendant add --name "Research"
gnostic config timeline add --title "Research notes"
```

Workspace entries require a matching local Workspace adapter in the host. The
default `gnostic` CLI build registers one kind, `filesystem`, so its fresh
configuration leaves `workspaces` empty until you add an entry.

The `filesystem` kind serves a local directory as a read-only Workspace. Edit
the manifest to add an entry; `config workspace add` writes the default kind, so
set `kind` by hand:

```json
{
  "id": "00000000-0000-4000-8000-000000000001",
  "kind": "filesystem",
  "name": "Project files",
  "uri": "/srv/project"
}
```

- `uri` is required and names the root. Use an absolute path or a `file:` URL.
  `gnostic serve` fails to start when the root is missing or is not a
  directory.
- The Workspace advertises two tools: `list_directory` and `read_file`. Each
  takes a Workspace-relative `path`; `list_directory` also accepts none for the
  root. Both require permission. There are no write tools.
- The Node that owns the Timeline asks for that permission, and the Workspace
  Node accepts its answer. The Workspace Node rejects a call from any other
  Node, but it identifies Nodes by their Axoloty source ID, which is not a
  credential. Broker access is the trust boundary: give it only to Nodes that
  may read the root.
- The Workspace's `uri`, including the root's absolute path, is advertised to
  every Node on the broker. Choose a root whose path you are willing to share.
- A tool cannot leave the root. The adapter rejects absolute paths, `..`
  components, and any path whose real location, after following symlinks, is
  not inside the root. A symlink that stays inside the root works. A failure
  comes back as a failed tool result and does not name paths outside the root.
- Output is bounded to fit the wire payload. A result that is cut ends with a
  `[truncated: ...]` line. `read_file` returns UTF-8 text only. Neither tool can
  page past the bound, so `list_directory` shows only the first names of a large
  directory, in sorted order among at most 4,096 entries.
- The adapter does not sandbox a Runtime process. A Runtime keeps whatever file
  access its operating-system user has.

Inspect the objects that a running Node advertises:

```sh
gnostic inspect list
gnostic inspect list --type ascendant
gnostic inspect object 00000000-0000-0000-0000-000000000000
```

The object inspection command requires an advertised object UUID. Workspace
tool calls use Axoloty's unary `me.atkn.gnostic.workspace.invoke` operation.
Gnostic does not expose direct file APIs for remote Workspaces.

Read payload-free live runtime state from a running Node. These commands use
the `me.atkn.gnostic.diagnostics.node`, `me.atkn.gnostic.diagnostics.ascendant`,
and `me.atkn.gnostic.diagnostics.timeline` operations, gated on the
`me.atkn.gnostic.capability.diagnostics` capability:

```sh
gnostic inspect node
gnostic inspect ascendant 00000000-0000-0000-0000-000000000000
gnostic inspect timeline 00000000-0000-0000-0000-000000000000
gnostic inspect events
```

`gnostic inspect node`, `gnostic inspect ascendant`, and `gnostic inspect
timeline` report backend health and quarantine, in-flight and completed Turn
counts, Workspace effective status, and observer drain statistics. They never
print a Turn body or a secret value. `gnostic inspect events` renders the
bounded raw wire-event stream as envelopes with a payload byte count; it never
prints the payload. Every command supports `--format json`. Every `inspect`
command also accepts `--config PATH`, which resolves the broker from the same
manifest that `gnostic serve --config PATH` reads.

## Run experiments

`gnostic experiment` forwards to the separately packaged
`gnostic-experiment` executable. Install it beside `gnostic` or on `PATH`.
The experiment tools keep their research dependencies out of the host build.

```sh
gnostic experiment replay --trace Documentation/Experiments/kit-replay-self-check.trace.json
gnostic experiment rlm-scenario-rating --artifact <artifact.json> --write-sheet <sheet.json>
```

The RLM live scenario remains unavailable after #611 retired the in-process
model loop. Its outer-consumer design is owned by #624 and its gateway tool is
deferred in #615.

`gnostic config validate` reports every problem with its manifest path and a
remediation hint, and exits non-zero when the manifest is invalid. Every
mutating `config` subcommand accepts `--dry-run`, which prints a redacted diff
of the resulting manifest and writes nothing.

Run the offline diagnostics before starting the Node. `gnostic doctor` checks
the manifest, backend-specific Runtime configuration, missing secrets, and
Workspace paths. ACP Runtime model selection stays in the Runtime
configuration. Add `--online` to also check broker reachability and the
protocol major, or `--check-provider` to probe endpoints for backend kinds
that declare provider settings:

```sh
gnostic doctor
gnostic doctor --format json
gnostic doctor --online
gnostic doctor --check-provider
```

`gnostic doctor` exits non-zero when any check is an error; warnings do not
fail the command. The `--format human|json` option is shared by `inspect`,
`config validate`, and `doctor`.

## Inspect the durable Turn event log

When `gnostic serve` runs with a durable Turn log (`--turn-log` or
`GNOSTIC_STATE_HOME`), `gnostic turn-log` reads it without changing it. The
command lists journaled turns grouped by Timeline and client turn id, verifies
each record checksum, and reports a torn or corrupt tail:

```sh
gnostic turn-log
gnostic turn-log --turn-log /var/lib/gnostic/turn-events-v1.jsonl
gnostic turn-log --format json
```

`gnostic turn-log` resolves the same path as `serve`: an explicit `--turn-log`,
else `GNOSTIC_STATE_HOME/turn-events-v1.jsonl`. With neither it reports that no
log is configured. It exits `2` when it finds a torn or corrupt tail and leaves
the tail in place; the writer-owned recovery truncates it on the next `serve`.

## Use the consumer session facade

External clients that connect, discover, and read the catalog programmatically
use `GnosticConsumerSession` from the `GnosticClient` library. The facade owns
the broker connection and a `NetworkCatalog`, so a consumer never imports the
CLI executable and never builds the generic Axoloty host objects.

```swift
import GnosticClient

let session = try GnosticConsumerSession(
    broker: GnosticBrokerSettings(
        host: "127.0.0.1",
        port: 1883,
        namespace: "gnostic",
        username: nil,
        password: nil
    ),
    identityName: "my-client",
    connectTimeout: .seconds(5),
    discoverTimeout: .seconds(5)
)
try await session.start()
try await session.discover()

let workspaces = await session.networkObjects()
    .filter { $0.objectType == GnosticObjectType.workspace }

let updates = await session.catalogUpdates()
for await change in updates {
    // Observe .advertised, .deadvertised, or .providerEvicted.
}

await session.stop()
```

`connectTimeout` bounds the wait for the transport to report online. When it
elapses, `start` tears the session down and throws
`GnosticConsumerSessionError.brokerUnreachable`. `discoverTimeout` bounds how
long `discover(timeout:)` collects resolve responses; a per-call timeout
overrides it. Empty credential strings are treated as absent, and a password
without a username is rejected before connecting.

A per-object deadvertisement removes only that provider's record and yields
`NetworkCatalogChange.deadvertised`. A lifecycle identity deadvertisement
removes every record owned by the provider and yields
`NetworkCatalogChange.providerEvicted`. Both are reflected by
`networkObjects(includeIncompatible:)` and `object(id:providerID:)`.

### Observe raw wire events for diagnostics

`session.rawEvents()` returns a bounded, best-effort stream of
`GnosticRawWireEvent` values for the session's own connection. It covers
advertisements, deadvertisements, discover and query responses, call/return
traffic, and channel traffic, including channels whose identifiers the caller
does not know in advance.

```swift
let raw = await session.rawEvents()
for await event in raw {
    // event.kind, event.sourceId, event.correlationId,
    // event.objectType, event.targetObjectId, event.channelId, event.payload
}
```

The stream retains at most 64 pending events and drops the oldest when an
observer falls behind, so it never blocks the runtime. It is diagnostic-only:
events are not persisted or replayed, and the envelope is not a contract for
automation. Use the typed clients for behavior.

## Run Turns from a consumer

`session.turnClient()` returns a `GnosticTurnClient` over the session's own
connection. It runs a Turn, replays it by client turn ID, streams its updates,
and answers permission requests.

```swift
let turns = try session.turnClient(promptTimeout: .seconds(120))
let result = try await turns.run(
    message: "Summarize the attached workspace.",
    timelineID: timelineID,
    clientTurnID: "summary-1"
)

// Re-read the same Turn without running it again.
let replay = try await turns.replay(
    timelineID: timelineID,
    clientTurnID: "summary-1"
)
```

Every call resolves the addressed Timeline from the catalog and requires its
Ascendant to advertise `textTurnInput`; pass `providerID` to pin the serve
explicitly. A stable `clientTurnID` names the Turn so the serve retains its
updates: `replay` re-reads them, and `updates` streams them. Omitting it leaves
the Turn unnamed and unreplayable. `replay` does not re-run the Turn, but a
second `run` with the same `clientTurnID` does start another Turn. There is no
`ascendant.turn.cancel` wire operation: cancelling the surrounding Swift `Task`
stops only the local wait, not a Turn the serve already started.

## Attach and invoke Workspaces from a consumer

`session.workspaceClient()` returns a `GnosticWorkspaceClient` for the
Workspace lifecycle a consumer drives.

```swift
let workspaces = try session.workspaceClient()
try await workspaces.attach(
    workspaceID: workspaceID,
    to: timelineID,
    approved: userApproved
)

let status = await workspaces.effectiveStatus(workspaceID: workspaceID)
let result = try await workspaces.invoke(
    workspaceID: workspaceID,
    toolID: "echo",
    arguments: ["message": .string("hello")]
)

try await workspaces.detach(workspaceID: workspaceID, from: timelineID)
```

`attach` refuses `approved: false` locally without a wire call. `attach` and
`detach` both require the Timeline's operating Ascendant to advertise
`workspaceAttachment`, so a Timeline whose Ascendant lacks it is refused locally
for either call. `invoke` requires the Workspace provider to advertise
`workspaceToolInvocation`. Attach and detach address the Timeline's serving
provider, while invocation addresses the Workspace's advertising provider. `attachmentStatus(workspaceID:)` reports the
Node's durable attachment intent; `effectiveStatus(workspaceID:)` reports
whether that intent is usable now.

Both clients are valid only while the session runs. After `session.stop()` later
calls fail by transport timeout; create a new client from a new session.

## Create and rename Timelines from a consumer

`session.timelineClient()` returns a `GnosticTimelineClient` over the session's
own connection. It creates a Timeline under a discovered Ascendant and renames a
discovered Timeline, using the existing `timeline.create` and `timeline.update`
serve handlers.

```swift
let timelines = try session.timelineClient()

let created = try await timelines.create(
    title: "Research",
    ascendantID: ascendantID
)

let renamed = try await timelines.update(
    timelineID: created.timelineID,
    title: "Research notes"
)
```

Every call resolves the serving provider from the catalog and requires the
Ascendant to advertise `timelineManagement`; discovery is refreshed only when
the target is absent. Pass `providerID` to `create` to pin the Ascendant's
provider. The client reuses the session transport, so a consumer
never opens a second connection for the same broker identity. Timeline deletion
is not exposed because no delete operation exists in the Gnostic wire contract.

## Catalog target failures

Every typed client resolves its target through one policy. The catalog is
refreshed at most once per call, and only when the target is absent (for a
node-wide diagnostics call, when no provider advertises diagnostics). After
that refresh the call fails with the error below. Capability checks read the
catalog as it stands and never refresh it. A pinned `providerID` that does not
own the target is `providerMismatch` for every client.

| Client | Failure | Public error |
| --- | --- | --- |
| Turn | Timeline absent, or no single operating Ascendant | `timelineUnavailable` |
| Turn | Timeline advertised by two providers | `timelineAmbiguous` |
| Turn | Pinned provider does not own the Timeline | `providerMismatch` |
| Turn | Operating Ascendant lacks `textTurnInput` | `missingCapability` |
| Workspace attach, detach | Timeline absent, or no single operating Ascendant | `timelineUnavailable` |
| Workspace attach, detach | Timeline advertised by two providers | `timelineAmbiguous` |
| Workspace attach, detach | Pinned provider does not own the Timeline | `providerMismatch` |
| Workspace attach, detach | Operating Ascendant lacks `workspaceAttachment` | `missingCapability` |
| Workspace invoke | Provider advertises no `workspaceToolInvocation` | `missingCapability` |
| Timeline create | Ascendant absent or ambiguous | `ascendantUnavailable`, `ascendantAmbiguous` |
| Timeline create | Pinned provider does not own the Ascendant | `providerMismatch` |
| Timeline update | Timeline absent, or no single operating Ascendant | `timelineUnavailable` |
| Timeline update | Timeline advertised by two providers | `timelineAmbiguous` |
| Timeline update | Operating Ascendant lacks `timelineManagement` | `missingCapability` |
| Timeline status | Timeline absent, or advertised by two providers | `timelineUnavailable`, `timelineAmbiguous` |
| Diagnostics node | No provider advertises diagnostics | `missingCapability` |
| Diagnostics node | Pinned provider does not advertise diagnostics | `nodeUnavailable` |
| Diagnostics node | More than one provider advertises diagnostics | `nodeAmbiguous` |
| Diagnostics ascendant | Ascendant absent, ambiguous, or pinned to another provider | `ascendantUnavailable`, `ascendantAmbiguous`, `providerMismatch` |
| Diagnostics ascendant | Ascendant lacks `diagnostics` | `missingCapability` |
| Diagnostics timeline | Timeline absent, ambiguous, or pinned to another provider | `timelineUnavailable`, `timelineAmbiguous`, `providerMismatch` |
| Diagnostics timeline | Operating Ascendant lacks `diagnostics`, or none names one | `missingCapability`, `timelineUnavailable` |

## Use ACP

`gnostic acp` is the supported ACP v1 stdio interface. It maps ACP sessions to
Gnostic Timelines and keeps backend transcript state private to the selected
Ascendant backend.

### External ACP agent backends

The optional `acp-client` backend runs an external ACP agent as an Ascendant
backend. Supported launch recipes, authentication, secret settings, the
agent-owned-tools boundary, and Timeline behavior are documented in the
[ACP backend operator guide](Documentation/Extending/ascendant-backends.md#using-an-acp-agent-backend).
Gnostic mediates permission requests, but the agent executes its own tools; it
does not receive Gnostic Workspace tools. Use the explicit, opt-in
[`make acp-live-smoke`](Documentation/Extending/ascendant-backends.md#opt-in-live-smoke)
target for one real Turn. It is not part of `make verify` or CI.

An ACP session resumes after the ACP child restarts while the same
`gnostic serve` process stays online. By default, a serve restart orphans
Timelines created at runtime, so a later resume or prompt fails with
`timelineUnavailable` and `session/list` omits the session (ADR 0008). The
session record stays on disk for diagnostics, marked ended.

Configuration migration explicitly rejects the removed `positronic` and
`letta` backend kinds and guides operators to an ACP v2 Runtime. Historical
execution state is not converted or deleted.

To create profiles for the generic
[`pi-acp-client`](https://github.com/phynics/pi-acp-client), query a running
Node:

```sh
gnostic acp profiles --json
```

Run `gnostic acp` as the stdio process for an ACP client. Like `serve`, it
accepts `--config PATH` to read broker defaults from a specific Node manifest. A
generated profile carries `--node` only when more than one Node advertises the
same Ascendant.
Node and Ascendant identities come from the manifest, so a captured profile
stays valid across a `gnostic serve` restart. `--provider` still pins one serve
process and is needed only for a Node that advertises no identity.

## Extend Gnostic

- [Integrate an ACP Runtime](Documentation/Extending/ascendant-backends.md)
- [Implement a Workspace adapter](Documentation/Extending/workspace-adapters.md)
- [Build an experiment on the platform kit](Documentation/Extending/experiment-kit.md)

## Develop and validate

Use the repository container for package development and validation:

```sh
make worktree-bootstrap
make verify
make docs-check
make harness-test
make container-smoke
```

`make verify` runs the documentation check and Swift test suite. The smoke
targets exercise the standalone runner, ACP clients, and container setup.
`make harness-test` runs the container command harness on the host with fake
runtimes. It covers `.devcontainer/run.sh`, the smoke delegation, the
missing-manifest guard, the dev-stack argument handling, the worktree build
root, and the host container wrapper, without building anything.

### Reproduce a flaky subprocess test

Swift Testing repetitions (ST-0024) stress the subprocess and ACP suites without
changing the gate. Run them inside the container:

```sh
make shell
swift test --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
  --build-system native -Xswiftc -warnings-as-errors \
  --filter GnosticCLITests.ACPSubprocessTests --repeat 20
```

`--repeat 20` bounds the run; `--repeat-until fail` stops at the first failure.
`make acp-smoke` remains the gate; repetitions only help reproduce an
intermittent failure.

### Soak the serve runtime

`make soak` runs `gnostic serve` with the deterministic ACP fixture agent and
drives scripted Turns for a configurable duration. It samples the serve
process's RSS, threads, file descriptors, authoritative journal bytes, and bounded
Turn-ledger sizes. The driver records each Turn's latency in milliseconds. The
run fails when a configured bound is exceeded, metrics are invalid, the driver
fails, metrics stop updating for more than three effective writer intervals,
or no Turns complete. The writer interval has a one-second minimum. It is separate from
`make verify`.

```sh
make soak
SOAK_DURATION_SECONDS=300 SOAK_MAX_RSS_KB=2097152 make soak
```

`SOAK_MAX_RSS_KB`, `SOAK_MAX_THREADS`, `SOAK_DURATION_SECONDS`,
`SOAK_TURNS`, and `SOAK_TURN_INTERVAL_MS` tune the run. These settings are
forwarded into the pinned container. Each run retains its logs, raw samples,
state, dependency lockfile, source revision, and exit status under a unique
`.testing/soak/run-*` directory. `SOAK_ARTIFACT_ROOT` selects a different parent
inside the mounted worktree. The TSV columns are timestamp, RSS KB, threads,
in-flight Turns, retained Timelines, retained identities, retained completions,
tombstones, completed bytes, identity capacity, completion capacity, file
descriptors, and journal bytes. Build logs and failing runs are retained too.

An eight-hour candidate run requires `CONTAINER_TIMEOUT` above 28,800 seconds.
This example submits a finite identified workload and observes resources for eight
hours:

```sh
CONTAINER_TIMEOUT=30000 SOAK_DURATION_SECONDS=28800 SOAK_TURNS=512 make soak
```
 Choose a Turn count below the configured identity capacity; exceeding it
is an expected admission failure, not a successful soak. This command alone
does not satisfy owner manual acceptance or external-peer conformance.

The retained ledger metrics describe Gnostic admission state. Runtime memory
and model context remain Runtime-owned.

### Run the RLM scenario live stages

The #354 pilot (Stage 2) and full matrix (Stage 3) call a real provider and
cost money. `gnostic experiment rlm-scenario` runs them using the provider,
models, and key of a configured Positronic Ascendant. It is a thin consumer of
the experiment kit: the round runner, artifact resume, metering, scoring rule,
and spend guard come from `GnosticKit`, and only the corpus snapshot, worker
preflight, and pinned-image gate are RLM-specific. Run it through the
container so each run records the pinned image:

```sh
make scenario-live CONFIG=path/to/manifest.json ARGS="--stage pilot --ascendant <uuid>"
```

Validate the handoff without spending first. This synthesises a throwaway
Ollama-backed manifest, starts both executors, and stops before any provider
call:

```sh
make scenario-live-preflight
```

It fails unless the run reaches `Dry run: no provider was contacted.`

Without `--confirm-spend` the command prints the plan and a worst-case ceiling,
checks that each executor starts, and contacts no provider. To run, add
`--confirm-spend` to `ARGS`. Each question runs once per executor by default;
`--repetitions` raises that (up to 3), and `--questions Q2 Q7` limits the
matrix to named questions. Tokens are always metered. On a per-token plan,
also pass `--input-price`, `--output-price`, and `--prices-date` to record
dollar cost; such a priced round also requires a `--max-cost` ceiling. The artifact under
`Documentation/Experiments/` is rewritten after every run, so re-running the
same command resumes the round. The command refuses to resume an artifact
whose fixed parameters differ. The matrix (`--stage matrix`) also needs
`--pilot` pointing at the completed pilot artifact, which carries the measured
cost projection. After a round, `gnostic experiment rlm-scenario-rating`
writes a blind rating sheet (`--write-sheet`) for an evaluator LLM and applies
its 0–10 scores (`--apply-scores`).

### Generate an SBOM

`make sbom` writes SPDX 3.0.1 and CycloneDX 1.7 SBOMs for the SwiftPM
dependency graph to `.testing/sbom/`. Use it to attach supply-chain metadata to
a release; it is not part of `make verify`. The output embeds a random serial
number and a creation timestamp, so it is not byte-deterministic, and SwiftPM
warns that it omits build-time conditionals. It also does not cover the
container's system packages, such as mosquitto and Node.js.

## Use the host container wrapper

The Linux `gnostic` binary that `make build` produces runs inside the
development container. Host tools that cannot run the Linux binary directly,
such as [`pi-acp-client`](https://github.com/phynics/pi-acp-client), call
`Scripts/gnostic-container.sh` as `gnostic`.

Install it on `PATH`:

```sh
ln -s "$PWD/Scripts/gnostic-container.sh" ~/.local/bin/gnostic
```

The wrapper matches the build cache that `make build` uses, so the main
checkout and every worktree share one build. Set `GNOSTIC_BUILD_ROOT` to pin a
different build, `GNOSTIC_IMAGE` to select the image, and `CONTAINER_RUNTIME`
to select `podman` or `docker`.

Run `gnostic --wrapper-info` to print the wrapper path, the repository root,
the build root, the binary path, the build revision, and the checkout
revision. The wrapper warns on standard error when the build revision differs
from the checkout revision, which means the build cache holds a binary from
another branch.

The wrapper forwards the `GNOSTIC_*` variables the CLI reads: `GNOSTIC_CONFIG`,
`GNOSTIC_HOST`, `GNOSTIC_PORT`, `GNOSTIC_NAMESPACE`, `GNOSTIC_STATE_HOME`,
`GNOSTIC_MQTT_*`, and `GNOSTIC_LLM_*`. The container sees `~/.gnostic` at
`/root/.gnostic` and `~/.local/state/gnostic` at `/root/.local/state/gnostic`.
`GNOSTIC_CONFIG` and `GNOSTIC_STATE_HOME` must name paths under those host
directories; the wrapper rejects any other path with a diagnostic instead of
silently dropping it.

## Choose a Timeline Project

Set a Timeline's Project independently from its attached Workspaces. A local
Project makes the Runtime session start in the selected repository directory;
a scratch Project gets a new owner-only temporary directory for its Session.

```sh
gnostic config timeline add "Repository" --project-local /work/repository
gnostic config timeline update <timeline-id> --project-scratch
```

You can also set `project` in the Timeline manifest to
`{"kind":"local","path":"/work/repository"}` or `{"kind":"scratch"}`.
Changing the Project `cwd` opens a new ACP Session on the same Timeline. Gnostic
reports no guarantee that the new Session retained prior model reasoning.
Neither placement is a filesystem sandbox: the Runtime can access paths
permitted to its operating-system user. Workspace tools remain MCP-gateway
mediated regardless of Project placement.

## Run the local ACP stack

Start an isolated stack for manual testing with pi-acp-client:

```sh
make dev-up
make dev-status
make dev-down
```

`make dev-up` builds Gnostic and starts a non-persistent Mosquitto broker on
`127.0.0.1:1884`. Set `DEV_BROKER_PORT` to use another port. The command copies
`~/.gnostic/config.json` into a scratch manifest or creates a default manifest.
It starts `gnostic serve` on a fresh namespace, writes a pi-acp-client profile,
and prints the `PI_ACP_CONFIG=... pi` command after profile discovery succeeds.

Stack state lives in `~/.gnostic/dev/stack`. The generated profile runs
`gnostic` from `PATH`, which should link to `Scripts/gnostic-container.sh`. The
profile survives a server restart; sessions created at runtime do not, because
their Timelines are not durable yet.

## Run the standalone runner

`gnostic-runner` is a development smoke-test executable. It hosts a Gnostic
Node through the same composition root as `gnostic serve`, advertises generic
Gnostic objects, and stays online until you stop it. The development container
provides an anonymous Mosquitto listener at `127.0.0.1:1883`. This path needs no
repository, LLM, or broker credentials.

Build and exercise the runner:

```sh
make resolve
make runner-smoke
```

The runner accepts `--host`, `--port`, and `--namespace`. Each missing option
falls back to `GNOSTIC_HOST`, `GNOSTIC_PORT`, or `GNOSTIC_NAMESPACE`, then to
`127.0.0.1`, `1883`, or `gnostic`. `--config` selects a Node manifest and falls
back to `GNOSTIC_CONFIG`; without either, the runner hosts the default graph.
The resolved broker always overrides the manifest's broker.

The runner starts an online Axoloty host when invoked without `--help`. It does
not ship the former fixture scenario. `make test` verifies test-only consumer
discovery, approved attachment, tool invocation, and Timeline readvertisement
against the same Mosquitto service.
