# Gnostic

Gnostic bridges PositronicKit orchestration with Axoloty networking.

## Status

Early proof of concept. Package code remains on `codex/gno-002` until Axoloty ships a remotely consumable release tracked by phynics/Axoloty#420.

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
