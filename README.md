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

## Bridge removal

Gnostic 0.2.0 removes the deprecated `gnostic bridge` command and its custom
`gnostic.*` JSON-RPC frontend. Use `gnostic acp` with a standard ACP client.
Pi users should migrate from the retired
[`gnostic-pi`](https://github.com/phynics/gnostic-pi) extension to
[`pi-acp-client`](https://github.com/phynics/pi-acp-client); existing Pi
transcripts start a new ACP-backed session because authority cannot be safely
rebound in place.

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
