# Gnostic

Gnostic bridges PositronicKit orchestration with Axoloty networking.

## Status

Early proof of concept. Axoloty's remotely consumable release is available through `0.3.0`.

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
