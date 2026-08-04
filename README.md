# Gnostic

Gnostic bridges PositronicKit orchestration with Axoloty networking.

## Status

Early proof of concept. Package code remains on `codex/gno-002` until Axoloty ships a remotely consumable release tracked by phynics/Axoloty#420.

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

## Planning

Work is tracked in GitHub Issues and the Gnostic Roadmap project. See `AGENTS.md` for the complete workflow.

- https://github.com/phynics/Gnostic/issues
- https://github.com/users/phynics/projects/6
