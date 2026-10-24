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
