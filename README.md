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

## Run the standalone runner

`gnostic-runner` is a development smoke-test executable. It advertises the
generic Gnostic objects and stays online until you stop it. The development
container provides an anonymous Mosquitto listener at `127.0.0.1:1883`.

```sh
make runner-smoke
```

The runner accepts `--host`, `--port`, and `--namespace`. When a flag is absent,
it reads `GNOSTIC_HOST`, `GNOSTIC_PORT`, and `GNOSTIC_NAMESPACE`, then uses
`127.0.0.1`, `1883`, and `gnostic` as defaults.

## Develop and validate

Use the repository container for package development and validation:

```sh
make worktree-bootstrap
make verify
make docs-check
make container-smoke
```

`make verify` runs the documentation check and the Swift test suite. The smoke
targets exercise the standalone runner, ACP clients, and container setup.
