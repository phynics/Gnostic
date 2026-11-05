# ACP Runtime integration

Every Runtime hosted by Gnostic v0.5 runs as a separate process and uses ACP
v2 over stdio. Gnostic does not load provider-specific model or tool loops
inside the host process. A Runtime owns its identity, instructions, model and
tool semantics, and lifecycle; Gnostic connects to and orchestrates it.

## Configure a Runtime process

Each configured Runtime instance uses the `acp-client` backend kind. Set the
path to its ACP executable and provide its arguments as a JSON array:

```sh
gnostic config backend set <ASCENDANT_UUID> command /path/to/acp-runtime
gnostic config backend set <ASCENDANT_UUID> args '["--stdio"]'
gnostic config validate
gnostic serve
```

The command starts one ACP process per configured Runtime instance. Runtime
model selection and provider credentials belong to that Runtime's own
configuration. Gnostic does not accept host-side `provider` or `model` keys
for ACP Runtime execution.

`gnostic config backend keys <ASCENDANT_UUID>` lists the settings accepted by
the selected backend. `gnostic doctor` checks the manifest and the configured
local environment before startup. Use `gnostic config validate` after every
manifest edit; it reports the failing key and its path.

## Configure the reference Runtime

The standalone reference Runtime, `gnostic-pk-runtime`, reads its model
settings from its environment. Set them with the backend's `env` setting, and
store the API key as a secret so that it never appears in `env`:

| Variable | Meaning |
| --- | --- |
| `GNOSTIC_PK_PROVIDER` | `openai` (default) or `openrouter`. |
| `GNOSTIC_PK_API_KEY` | The provider's API key. Required unless `GNOSTIC_PK_SCRIPTED=1`. |
| `GNOSTIC_PK_MODEL` | The model name. Defaults to `gpt-4o-mini` for `openai` and `openai/gpt-4o-mini` for `openrouter`. |
| `GNOSTIC_PK_ENDPOINT` | An absolute `http` or `https` URL that replaces the provider's default endpoint. |
| `GNOSTIC_PK_STATE_DIR` | The directory for the Runtime's session file. |
| `GNOSTIC_PK_SCRIPTED` | `1` selects a scripted model that needs no provider. |

`openrouter` keeps the endpoint's path, so it works behind a proxy that mounts
the API under a prefix. `openai` sends every request to `<root>/v1/...`, so it
accepts an endpoint with no path or with `/v1`. It rejects any other path at
startup instead of dropping it. The Runtime also stops at startup when the
provider is unknown or the endpoint is not an absolute URL, and its error names
the setting.

```sh
gnostic config backend set <ASCENDANT_UUID> command /path/to/gnostic-pk-runtime
gnostic config backend set <ASCENDANT_UUID> env '{"GNOSTIC_PK_PROVIDER":"openrouter","GNOSTIC_PK_MODEL":"openrouter/free"}'
printf '%s' "$OPENROUTER_API_KEY" | gnostic config backend set-secret <ASCENDANT_UUID> env-secret.GNOSTIC_PK_API_KEY
gnostic config validate
```

## Host implementation boundary

`AscendantBackend` is an internal adapter contract used by the Node runtime
supervisor. The production ACP adapter owns process launch, stdio framing,
session setup, and recovery. Host SPI registration exists for composition and
test fixtures only; it is not a supported Runtime extension point. A new
Runtime integration must implement ACP v2 in an independent process and use
the `acp-client` configuration.

Tests may register an in-process echo adapter to exercise generic lifecycle
behavior. That fixture does not represent a production Runtime kind or an
approved architecture exception.
