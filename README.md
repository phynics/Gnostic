# Gnostic

Gnostic 0.3.0 hosts Ascendant backends and exposes them over Axoloty. The
bundled Ascendant backend is `positronic`. The bundled local Workspace backend
is `echo`.

The [0.3.0 compatibility declaration](Documentation/Compatibility/0.3.0.md)
lists the protocol, manifest, migration, and intentional 0.2 breaks.

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

## Use ACP

`gnostic acp` is the supported ACP v1 stdio interface. It maps ACP sessions to
Gnostic Timelines and keeps backend transcript state private to the selected
Ascendant backend.

To create profiles for the generic
[`pi-acp-client`](https://github.com/phynics/pi-acp-client), query a running
Node:

```sh
gnostic acp profiles --json
```

Run `gnostic acp` as the stdio process for an ACP client. Pass `--ascendant`
and `--provider` when a broker advertises more than one matching object.

## Extend Gnostic

- [Implement an Ascendant backend](Documentation/Extending/ascendant-backends.md)
- [Implement a Workspace adapter](Documentation/Extending/workspace-adapters.md)

## Develop and validate

Use the repository container for package development and validation:

```sh
make worktree-bootstrap
make verify
make docs-check
make container-smoke
```

`make verify` runs the documentation check and Swift test suite. The smoke
targets exercise the standalone runner, ACP clients, and container setup.
`make wrapper-test` runs the fake-runtime harness for the host wrapper below.

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

Run `gnostic --wrapper-info` to print the wrapper path, the build root, the
binary path, and the revision the build was stamped with. The wrapper warns on
standard error when that revision differs from the checkout it lives in, which
means the build cache holds a binary from another branch.

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
`gnostic` from `PATH`, which should link to `Scripts/gnostic-container.sh`.
Restart pi after restarting the server because each server process has a new
provider ID.

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
