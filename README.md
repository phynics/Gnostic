# Gnostic

Gnostic 0.4.2 hosts Ascendant backends and exposes them over Axoloty. The
bundled Ascendant backend is `positronic`. The bundled local Workspace backend
is `echo`.

The [0.4.2 compatibility declaration](Documentation/Compatibility/0.4.2.md)
records the load-time cancellation-shield fix this release carries. The
[0.4.1 declaration](Documentation/Compatibility/0.4.1.md) records the
deployment-target fix. The
[0.4.0 declaration](Documentation/Compatibility/0.4.0.md) lists the public
consumer clients and the dependency exception. The [0.3.0 declaration](Documentation/Compatibility/0.3.0.md) remains
authoritative for the protocol, manifest, migration, and intentional 0.2
breaks.

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

Start the Node after configuring an LLM provider and model:

```sh
gnostic config positronic set <ASCENDANT_UUID> --provider <PROVIDER> --model <MODEL>
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
gnostic config workspace add --name "Echo" --uri "echo://local"
```

Inspect the objects that a running Node advertises:

```sh
gnostic inspect list
gnostic inspect list --type ascendant
gnostic inspect object 00000000-0000-0000-0000-000000000000
```

The object inspection command requires an advertised object UUID. Workspace
tool calls use Axoloty's unary `me.atkn.gnostic.workspace.invoke` operation.
Gnostic does not expose direct file APIs for remote Workspaces.

## Use the consumer session facade

External clients that connect, discover, and read the catalog programmatically
use `GnosticConsumerSession` from the `GnosticCore` library. The facade owns
the broker connection and a `NetworkCatalog`, so a consumer never imports the
CLI executable and never builds the generic Axoloty host objects.

```swift
import GnosticCore

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

`attach` refuses `approved: false` locally without a wire call, and requires the
Timeline's Ascendant to advertise `workspaceAttachment`; `invoke` requires the
Workspace provider to advertise `workspaceToolInvocation`. Attach and detach
address the Timeline's serving provider, while invocation addresses the
Workspace's advertising provider. `attachmentStatus(workspaceID:)` reports the
Node's durable attachment intent; `effectiveStatus(workspaceID:)` reports
whether that intent is usable now.

Both clients are valid only while the session runs. After `session.stop()` later
calls fail by transport timeout; create a new client from a new session.

## Use ACP

`gnostic acp` is the supported ACP v1 stdio interface. It maps ACP sessions to
Gnostic Timelines and keeps backend transcript state private to the selected
Ascendant backend.

An ACP session resumes after the ACP child restarts while the same
`gnostic serve` process stays online. A serve restart orphans Timelines created
at runtime, so a later resume or prompt fails with `timelineUnavailable` and
`session/list` omits the session; ADR 0008 records the decision and the
deferred durability work. The session record stays on disk for diagnostics,
marked ended.

To create profiles for the generic
[`pi-acp-client`](https://github.com/phynics/pi-acp-client), query a running
Node:

```sh
gnostic acp profiles --json
```

Run `gnostic acp` as the stdio process for an ACP client. A generated profile
carries `--node` only when more than one Node advertises the same Ascendant.
Node and Ascendant identities come from the manifest, so a captured profile
stays valid across a `gnostic serve` restart. `--provider` still pins one serve
process and is needed only for a Node that advertises no identity.

## Extend Gnostic

- [Implement an Ascendant backend](Documentation/Extending/ascendant-backends.md)
- [Implement a Workspace adapter](Documentation/Extending/workspace-adapters.md)

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

`gnostic-runner` is a development smoke-test executable. It advertises generic
Gnostic objects and stays online until you stop it. The development container
provides an anonymous Mosquitto listener at `127.0.0.1:1883`. This path needs no
repository, LLM, or broker credentials.

Build and exercise the runner:

```sh
make resolve
make runner-smoke
```

The runner accepts `--host`, `--port`, and `--namespace`. Each missing option
falls back to `GNOSTIC_HOST`, `GNOSTIC_PORT`, or `GNOSTIC_NAMESPACE`, then to
`127.0.0.1`, `1883`, or `gnostic`.

The runner starts an online Axoloty host when invoked without `--help`. It does
not ship the former fixture scenario. `make test` verifies test-only consumer
discovery, approved attachment, tool invocation, and Timeline readvertisement
against the same Mosquitto service.
