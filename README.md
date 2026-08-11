# Gnostic

Gnostic bridges PositronicKit orchestration with Axoloty networking.

## Status

Early proof of concept. The package uses the released PositronicKit `3.4.2`
surface and the Axoloty discovery revision that follows the `0.3.0` release.

## Discovered workspaces

Gnostic can inspect advertised network objects with `list_network_objects` and
`inspect_network_object`. A discovered workspace is imported only when one
available, well-formed provider advertises it. `attach_workspace` requires user
approval, imports the workspace as a runtime reference, attaches it through
PositronicKit's `TimelineManager`, and readvertises the changed Timeline.

Attached workspaces expose only their advertised custom tool definitions. Tool
calls use Axoloty's unary `me.atkn.gnostic.workspace.invoke` Call/Return
operation; direct file APIs are intentionally unsupported. Deadvertised,
malformed, or ambiguous advertisements cannot be attached or executed.

## ACP frontend

`gnostic acp` is the supported stable ACP v1 stdio agent. It projects one
Gnostic Ascendant and maps ACP sessions to authoritative PositronicKit
Timelines. The process owns one Axoloty/MQTT connection and accepts text
prompts, Timeline resume/list/close, cancellation, and replay metadata.

Discover profiles for the generic [`pi-acp-client`](https://github.com/phynics/pi-acp-client)
extension with:

```sh
gnostic acp profiles --json
```

The old `gnostic bridge` command remains available for one compatibility
release and prints a deprecation warning. It continues to serve the custom
`gnostic.*` protocol until a subsequent release removes it after the announced
compatibility window.

## Legacy JSON-RPC bridge

`gnostic bridge` is a long-lived JSON-RPC 2.0 stdio frontend for pi and other
process hosts. It reads one LF-delimited request per line from stdin and writes
responses to stdout, while sharing exactly one Axoloty/MQTT connection for
discovery, timeline operations, chat, workspace attachment, and approved
workspace-tool invocation. Logs never use stdout. Start it with the configured
broker or override `--host`, `--port`, and `--namespace`.

## Development

Canonical development uses the repository container:

```sh
make container-smoke
make shell
```

After `Package.swift` lands:

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
