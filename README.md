# Gnostic

Gnostic 0.3.0 bridges PositronicKit orchestration with Axoloty networking.

## Delivered baseline

The 0.3 package delivers the protocol-major-2 Ascendant/Turn contract,
manifest-v2 persistence with v1 migration, lifecycle-safe multi-backend hosting,
and authoritative Timeline/Workspace discovery and attachment. The bundled
Ascendant backend is `positronic`; the local Workspace backend is `echo`.

`GnosticPositronicAtlas` is an optional scaffold for future Positronic-specific
continuity work. It has no Atlas behavior in this release and is not a
dependency of `GnosticCore`. Narrative has been removed from Core and is
superseded by Atlas as recorded in [ADR 0004](Documentation/Architecture/ADRs/0004-atlas-supersedes-narrative.md).

See the [0.3.0 compatibility declaration](Documentation/Compatibility/0.3.0.md)
for the protocol, migration, bundled implementation, and intentional 0.2
break details.

## Discovered workspaces

Gnostic can inspect advertised network objects with `list_network_objects` and
`inspect_network_object`. A discovered workspace is imported only when one
available, well-formed provider advertises it. `attach_workspace` requires user
approval and routes through Gnostic's authoritative Workspace service. Gnostic
records attachment intent in `NodeRegistry`, projects it into the Positronic
backend, and readvertises the changed Timeline.

Attached workspaces expose only their advertised custom tool definitions. Tool
calls use Axoloty's unary `me.atkn.gnostic.workspace.invoke` Call/Return
operation; direct file APIs are intentionally unsupported. Deadvertised,
malformed, or ambiguous advertisements cannot be attached or executed.

## ACP frontend

`gnostic acp` is the supported stable ACP v1 stdio agent and the sole
user-facing interface for running Turns. There is no direct interactive
`gnostic turn` command. ACP projects one Gnostic Ascendant and maps its sessions
to authoritative Gnostic Timelines,
represented privately as PositronicKit Threads inside the built-in adapter. The process owns one Axoloty/MQTT connection and accepts text
prompts, Timeline resume/list/close, cancellation, and replay metadata.

Discover profiles for the generic [`pi-acp-client`](https://github.com/phynics/pi-acp-client)
extension with:

```sh
gnostic acp profiles --json
```

## Compatibility

The pre-1.0 0.2 network and schema-v1 contracts are intentionally not
interoperable with 0.3. Use the Ascendant/Turn and manifest-v2 contracts, and
use `gnostic acp` with a standard ACP client.

## Development

Canonical development uses the repository container:

```sh
make container-smoke
make shell
make docs-check
```

For package development:

```sh
make worktree-bootstrap
make verify
```

## Runner smoke path

The development container includes a local, anonymous Mosquitto listener at
`127.0.0.1:1883`. No repository, LLM, or broker credentials are required.

Run the deterministic fixture scenario through the configured broker:

```sh
make resolve
make runner-smoke
```

Broker settings may be supplied with command-line arguments (`--host`, `--port`,
and `--namespace`) or `GNOSTIC_HOST`, `GNOSTIC_PORT`, and `GNOSTIC_NAMESPACE`.
The fixture advertises `list_files`, `read_file`, and `workspace_echo` over the
generic unary workspace invocation route. `make test` runs the full consumer
discovery, approved attachment, tool invocation, and Timeline readvertisement
verification against the same local Mosquitto service.
