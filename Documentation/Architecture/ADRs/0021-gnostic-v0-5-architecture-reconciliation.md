# ADR 0021 — Gnostic v0.5 architecture reconciliation

## Status

**Accepted** (2026-10-20). This record is the binding architecture contract for
Gnostic 0.5.0. It reconciles decisions from [ADR 0017](0017-acp-first-host-and-harness-agent.md)
through [ADR 0020](0020-timeline-first-primitives.md) without deleting their
historical rationale. Its owner issue is
[GNO-ACPF-019 #640](https://github.com/phynics/Gnostic/issues/640), under
[Epic #602](https://github.com/phynics/Gnostic/issues/602). The release gate is
[Epic #551](https://github.com/phynics/Gnostic/issues/551).

This decision changes no code, wire contract, manifest, or stored format by
itself. Delivery is tracked by the #602 and #551 child issues named below.

## Context and supersession

ADRs 0017–0020 set the direction in successive steps. Their accepted contracts
now disagree on Runtime placement, Timeline durability, Turn admission, Project
placement, and the v0.5 release boundary. ADR 0021 is the single source for the
v0.5 architecture. Earlier records remain useful for their history. When an
earlier section conflicts with this record, this record governs.

The following map identifies each superseded or amended section. Unlisted
historical context, evidence, and link sections stay as background; they do not
override the contracts below.

### ADR 0017

- **§1, ACP is the Ascendant Backend boundary:** the ACP process boundary stays.
  The Ascendant identity and the statement that Gnostic owns Ascendant identity
  are superseded. Gnostic owns Timelines and Runtime instances, with no Agent or
  Ascendant primitive.
- **§2, Timeline record:** the normalized entity record is superseded by the
  ordered, lossless Timeline journal in §5. Runtime session state remains a
  Runtime-owned projection.
- **§3, Workspace gateway:** gateway-mediated Workspace tools remain. The
  requirement to connect the Runtime to Axoloty or MQTT does not apply. The
  Runtime talks to its local Node over ACP v2 on stdio. Gateway MCP transport
  selection remains as stated in ADR 0019 §6.
- **§4, subagents:** automatic conversion of Runtime subagents into child
  Timelines is deferred. A child Timeline remains a possible later feature.
- **§5, Ascendant definition:** superseded. Runtime instance configuration and
  Timeline identity replace it.
- **§6, one harness agent and two module layers:** superseded. The PositronicKit
  reference Runtime is an independent ACP process. No inner experiment or
  research consumer is required in the host release.
- **§7, PositronicKit firewall:** amended. The host has no PositronicKit in its
  dependency closure. Only the standalone PositronicKit 7 reference Runtime
  executable may depend on PositronicKit. The former harness-target allow-list
  and special-Node interpretation are retired.

### ADR 0018

- **§1–§2, Agent identity and naming:** superseded. Gnostic has no Agent
  primitive or Agent definition. ACP protocol roles keep their ACP names; Gnostic
  identity uses Timeline and Runtime instance.
- **§3, spans:** the one-open-span invariant remains. Cross-Runtime seeding,
  whole-Timeline transfer, and automatic subagent lineage are not v0.5 features.
  A Project change opens a new Session record on the same Timeline (§6).
- **§4, ACP Turn payloads:** the Timeline envelope and ACP v2 payload boundary
  remain. Admission, busy rejection, retries, completion, and cancellation are
  governed by §4 here.
- **§5, Axoloty:** discovery and routing remain. Gnostic alone owns Timeline
  authority, admission, journaling, Runtime supervision, and Workspace access
  decisions (§7).
- **§6, roots and gateway tools:** root delivery is not part of v0.5. The
  selected Project supplies `cwd`; attached Workspaces reach the Runtime through
  the Gnostic MCP gateway (§6).
- **§7, capabilities:** Gnostic-defined capability names are retired. A Runtime
  instance advertises its ACP v2 `initialize` capabilities as discovery data.

### ADR 0019

- **§1, ACP v2 model:** retained. v0.5 supports no ACP v1 path. ACP v2 remains
  opt-in and labeled preview under T1 and T2.
- **§2, Turn lifecycle:** insertion and completion on `idle` remain. The queue
  and quiet-period idle inference are superseded by the single-active-Turn and
  pre-insertion busy rejection in §4.
- **§3, updates outside a Turn:** out-of-Turn updates belong to the open span.
  The Timeline journal stores them durably under §5, rather than only when an
  optional record is enabled.
- **§4–§5, permissions and cancellation:** retained with the v2 `cancelled`
  outcome for an unanswered permission request (amended 2026-10-21, see
  ADR 0019 §4) and the pre-insertion versus post-insertion cancellation split.
- **§6, MCP transports and roots:** the advertised MCP transport order remains.
  Project directories are not Workspace roots. Workspaces use gateway tools.
- **§7, session baseline:** a Runtime must advertise the required ACP v2
  session methods. Ambiguous resume state is handled under §6 here.
- **§8, Gnostic-owned v2 wire model:** retained. The model is shared by the
  host adapters and the standalone reference Runtime.
- **§9, in-process backend kinds:** superseded. v0.5 removes the in-process
  `positronic` and `letta` kinds.
- **T1–T3:** retained. Gnostic rejects ACP v1, ships ACP v2 as an opt-in
  preview, and answers an unanswered permission request with the v2
  `cancelled` outcome.

### ADR 0020

- **§1, no Agent and Timeline identity:** retained. This record makes the
  Timeline journal durable and fixes its owning Node (§2, §5).
- **§2, Timeline content:** the lossless ACP update log and rebuildable
  projections remain. The journal now also contains ordered Gnostic
  orchestration events, replay epochs, integrity checks, and a versioned format
  (§5). Conditional in-memory-only Timeline authority is superseded.
- **§3, handoff:** native resume on the same Runtime remains. Whole-Timeline
  handoff and synthetic cross-Runtime context seeding are deferred (§9).
- **§4, Session record:** stickiness and native resume remain. A changed Project
  creates a new Session record on the same Timeline. Ambiguous Runtime state is
  not treated as a successful resume or a confirmed loss (§6).
- **§5, Node-hosted Runtime instances:** Runtime instances remain Node-scoped.
  A Timeline has one fixed owning Node. Runtime Nodes route requests; they do
  not gain Timeline authority (§7).
- **§6, scratch-only placement:** superseded. v0.5 supports an explicit local
  Project or a Gnostic-managed scratch Project. A Project change creates a new
  Session record. Workspaces remain gateway tools (§6).
- **§7, Runtime kinds and special Nodes:** superseded. Every Runtime, including
  the in-repository PositronicKit reference implementation, uses ACP v2 over
  stdio. The reference Runtime is a supervised process, not a special Axoloty
  Node, and it does not connect to an MQTT broker (§3).
- **§8, Gnostic capabilities:** the retirement remains. ACP `initialize`
  capabilities are advertised verbatim and used only where the protocol
  requires them.
- **§9, Axoloty:** discovery and routing remain. Axoloty remains the
  Node-to-Node fabric, not part of the local Runtime process loop (§7).
- **O9:** superseded. A PositronicKit process is not a special Node.

The previous ADRs' invariants, alternatives, consequences, and delivery notes
remain historical where they describe a superseded decision. The invariants and
fitness checks in this record govern v0.5.

### Other related records

- [ADR 0004](0004-atlas-supersedes-narrative.md): Atlas remains a parked design
  reference, not a Runtime or host dependency.
- [ADR 0005](0005-core-positronic-dependency-boundary.md): the sole
  PositronicKit dependency exception is the standalone reference Runtime
  executable. No test target or transitional host target is exempt.
- [ADR 0011](0011-external-acp-backends.md): the ACP and Workspace gateway
  boundaries remain. Gnostic owns no Agent identity, and every Runtime uses the
  v0.5 ACP v2 stdio contract.
- [ADR 0013](0013-experimentation-platform.md): Module records and lifecycle
  remain. Research Modules are not required to build or run the v0.5 host.
- [ADR 0015](0015-file-backed-timeline-runtime-repository.md): the authoritative
  Timeline journal supersedes the Positronic transcript store. v0.5 does not
  migrate those historical files.
- [ADR 0016](0016-ouroboros-akasha-executor-placement.md): Ouroboros and Akasha
  remain parked design references. A future experiment that needs a model loop
  runs as an independent ACP Runtime process.

## Decision

Gnostic v0.5 records work on Timelines owned by one Node, drives every
Runtime through ACP v2 over stdio, and treats the owning Node's durable
Timeline journal as the authoritative record. The subsections below fix the
resulting identity, execution, Turn, journal, session, distribution,
security, portability, experimental, and release contracts. They supersede or
amend ADRs 0017 through 0020 as described under Context and supersession.

### Purpose and identity

Gnostic records work. It does not own a model, Agent, or harness identity.

- A **Node** is a Gnostic host. It owns each Timeline created there and stores
  that Timeline's journal. It may host Runtime instances or route to a Runtime
  instance on another Node.
- A **Timeline** is durable work identity. It contains ordered Turns in spans
  and remains owned by its original Node. Runtime sessions cannot redefine or
  erase its identity.
- A **Runtime instance** is one configured ACP Runtime on one Node. It owns its
  process, install, arguments, environment, authentication, advertised model
  catalog, and session configuration defaults. Gnostic records the instance ID,
  version, and launch fingerprint for each span.
- A **Session record** links a Timeline to one Runtime instance and one ACP
  `sessionId`. It records the exact Project `cwd`, session options, safe MCP
  references, and the last Turn acknowledged by that session. It stores no MCP
  credential values.
- A **Project** supplies the Runtime session `cwd`. It is either an operator-
  selected local directory or a Gnostic-managed scratch directory.
- A **Workspace** is a capability resource attached to a Timeline. It reaches
  every Session as tools through the Gnostic MCP gateway.
- A **Turn** is one admitted, Timeline-addressed operation. It carries a
  Gnostic envelope around ACP v2 prompt and update payloads.

There is no Gnostic Agent or Ascendant primitive in v0.5. Clients create
Timelines and select Runtime instances. A Runtime owns its instructions, tools,
model context, compaction, and caches.

### Execution boundary

Gnostic communicates with every Runtime through one contract: ACP v2 JSON-RPC
over stdio. A Gnostic Node launches and supervises the process. An adapter may
run the Runtime on another Node, but the Runtime still speaks ACP locally to
that Node.

The standalone PositronicKit 7 reference Runtime is an independent executable.
It does not link the Gnostic host or join Axoloty. It has no MQTT connection.
The Gnostic Node owns its process lifecycle and passes the Gnostic gateway as
an MCP server. The Runtime imports the shared Gnostic ACP v2 wire model from
`GnosticACPWire`. It does not link `GnosticProtocol` or Axoloty.

PositronicKit stays out of every host target and its transitive dependency
closure. Only the standalone reference Runtime executable may depend on
PositronicKit. No test target or host shim receives an exception. Other Runtime
implementations need no PositronicKit dependency.

The v0.5 adapters accept ACP v2 only. They reject ACP v1 without translation or
fallback. The v2 path remains an opt-in preview until ACP v2 stabilizes. MCP
transport selection for Workspace tools follows the order in ADR 0019 §6 and
uses only transports the Runtime advertises.

### Turn semantics

Gnostic admits at most one active foreground Turn on a Timeline. A distinct
Turn submitted while another Turn is active receives a busy error before
Gnostic sends `session/prompt`. Gnostic does not queue it and does not insert
its user message. The Gnostic JSON-RPC error is `-32001`, with message
`Timeline is busy` and data `{"code":"timelineBusy","retryable":true}`.

Admission is idempotent by `clientTurnID` and the RFC 8785 canonical digest of
the prompt content plus the ACP version tag. An identical retry returns the
existing admission or Turn state. It never sends a second prompt. A different
prompt under the same ID is a conflict.

Gnostic durably records admission before it dispatches the prompt. It sends
`session/prompt` at most once. A successful response binds the Turn to the
Runtime's `messageId`; an error response means the prompt was not inserted. If
the response is lost, the Turn ends as `insertionUnknown`. Gnostic does not
guess, retry, or bind a later message to it.

A Turn ends when insertion is confirmed and Gnostic has observed the first
`idle` `state_update` after prompt dispatch. The Runtime's stop reason sets the
terminal result. An omitted stop reason produces `endedUnspecified`. Updates
outside the active Turn belong to the Timeline's open span.

Before insertion, cancellation uses `$/cancel_request`. If the Runtime confirms
that cancellation prevented insertion with `-32800`, the Turn ends as
`cancelled`. If insertion succeeded, Gnostic follows with `session/cancel`.
After insertion, Gnostic uses `session/cancel`. The Turn ends on the next
`idle` update.

Every permission request gets a reply. If no client answers within the
configured bound, Gnostic answers with the v2 `cancelled` outcome and records
the decision as `unavailable`. It does not choose a denial option for the
client. The answer ends that one request and never the Turn, because the
pinned ACP v2 SDK rejects the agent's request promise when the client answers
with a JSON-RPC error.

### Timeline journal

The Timeline journal is Gnostic's authoritative, durable record. The owning
Node appends immutable events in logical order. Each event has a format version,
Timeline ID, replay epoch, monotonic sequence number, timestamp, causal span,
checksum, and event payload.

The journal interleaves Gnostic events, such as Turn admission, Workspace
attachment, Project changes, and Session transitions, with the Runtime's ACP
v2 updates. It stores each ACP update exactly as received, including `_meta`,
unknown kinds, and updates outside a Turn. Gnostic rebuilds folded messages,
tool calls, plans, terminals, usage, and current Session views from this log.
Those projections are indexes, not alternate records.

The owning Node syncs an admission before it dispatches a prompt. It syncs each
event before it forwards that event to subscribers or peers. The Turn event log
remains separate and digest-only. The Timeline journal holds conversation
content.

The journal format is versioned. A reader rejects an unknown version rather
than reinterpreting it. Any format migration is explicit and preserves the
source until the new journal passes validation. Recovery truncates an
uncommitted torn tail. Checksums detect event corruption. Corruption in a
committed prefix quarantines the Timeline as read-only and reports a diagnostic;
the Node does not skip the bad event or continue appending. Replay epochs expose
divergent or stale replay instead of merging it silently.

The [Timeline journal format reference](../Timeline-Journal-Format.md) defines
the v1 frame, storage path, checksum, and schema migration rules.

An owner Node without a writable journal cannot admit a Timeline in v0.5. It
does not silently replace the authoritative journal with in-memory state.

### Session lifecycle and Project placement

Gnostic resumes a Session only on the same Runtime instance, with its original
`sessionId` and exact `cwd`. The Runtime must advertise the ACP v2 session
capabilities required for the operation. Gnostic records those capabilities
verbatim. It checks optional methods, such as `session/fork`, only when the
Runtime advertises them.

A Session record has one of four states:

- `live`: the Runtime session is active;
- `resumable`: the Runtime has confirmed that native resume is available;
- `lost`: the Runtime definitively rejects resume or confirms deletion;
- `ambiguous`: a transport or process failure prevents Gnostic from confirming
  whether the Runtime session survived.

Gnostic does not turn an ambiguous result into `lost` or `resumable`. It does
not issue a new prompt against that Session. A confirmed resume continues the
existing Session. A definitive rejection allows Gnostic to open a new Session
record under the same Timeline. It reports the new Session without claiming
that the Runtime retained its prior model context.

Changing the Project `cwd` always opens a new Session record and span on the
same Timeline. The previous Session may be closed according to the Runtime's
ACP support. The new Session starts with the selected Project, not with a
promise of prior model reasoning. Gnostic does not synthesize cross-Runtime
prompts from the Timeline journal in v0.5.

A local Project uses the operator-selected directory as `cwd`. A scratch
Project uses a clean Gnostic-managed directory for that Session. Scratch and
local Projects are not sandboxes. The Runtime process can access any path
allowed to its operating-system user.

Attached Workspaces are not Project directories. Gnostic serves their tools
through its MCP gateway and records the attachment and availability state.
Gateway authorization applies to gateway calls. It does not constrain the
Runtime's own filesystem or shell tools.

### Distribution and the Axoloty fabric seam

One Node owns each Timeline for its lifetime. It owns the journal, Turn
admission, replay decisions, and Workspace authorization for that Timeline.
Other Nodes route operations and observation requests to the owner over
Axoloty. An owner may route Runtime work to an ACP process supervised by a
different Node.

The Gnostic gateway resolves a Workspace call at the Workspace's owning Node.
The owning Node checks current attachment, effective status, permissions, and
tool membership before it invokes the Workspace. A two-Node v0.5 deployment
must prove remote Turn dispatch and remote Workspace invocation through this
path.

Axoloty remains the discovery, liveness, and routing fabric between Gnostic
Nodes. It does not own Timelines, admit Turns, journal ACP updates, supervise
local Runtime processes, or authorize Workspace calls. Axoloty Core's
observable-object conveniences do not replace Gnostic records. The local ACP
stdio connection between a Node and its Runtime does not use Axoloty or MQTT.

If the Timeline owner disappears, the Timeline is unavailable until that owner
returns. A peer's departure or last-will message does not prove that execution
stopped. Gnostic does not transfer Timeline authority or fail over automatically.

### Security scope

Operators trust Runtime processes they configure. A Runtime runs with the
operating-system permissions of its process owner. Gnostic makes no filesystem
sandbox claim for either local or scratch Project placement.

The MCP gateway enforces Gnostic's Workspace attachment, effective-status,
permission, and tool-membership decisions for calls made through the gateway.
It cannot mediate a Runtime's own tools or direct filesystem access. Session
records and journal metadata contain references to MCP servers, not their
credentials. Runtime secrets stay with the Runtime instance configuration and
do not enter the Timeline journal.

### Context portability

The Timeline journal preserves what Gnostic sent and what the Runtime returned.
It is an advisory record for future tools and for any later Timeline-linked
context artifacts. It is not the Runtime's model context, and it does not prove
that another Runtime can reconstruct that context.

v0.5 supports native resume on the same Runtime instance. It does not require
cross-Runtime context handoff, synthetic seeding, or continuity of model
reasoning after a Project change. A later context-transfer feature needs its
own decision, loss model, and acceptance tests.

### Experimental architecture

The PositronicKit 7 reference Runtime is an independent ACP implementation. It
does not make research code a host dependency. Each Runtime implementation
uses the same ACP v2 stdio boundary, regardless of its language or model loop.

Experiments that need a model loop run as independent Runtime processes.
Research consumers that need only Timeline data use the stable Gnostic
consumer products. No experiment, benchmark, or research package is required
to build or run the Gnostic host for v0.5. Inner experiments remain parked
until a separate issue defines their need and owner.

### v0.5 release contract

Gnostic 0.5.0 is a source- and wire-breaking minor release over 0.4.2. It makes
one `protocolMajor` increment and removes the Gnostic-owned Ascendant and Agent
contracts. A 0.4.2 peer does not interoperate with protocol major 3.

`GnosticProtocol` and `GnosticClient` are the stable Swift products planned for
0.5.0. ACP v2 remains an opt-in preview outside the 0.5.x stability promise.
Gnostic rejects ACP v1. No v1 compatibility adapter ships in Gnostic.

Operators migrate the immediate pre-v0.5 schema-v2 configuration with the
explicit migration tool in #642. The tool provides a dry run, creates a
backup, and reports configurations it cannot map safely. Gnostic does not
convert historical Turn logs, Timeline databases, Runtime sessions, or
experiment traces. It leaves those files in place and does not claim that v0.5
can resume them.

The v0.5 release removes the in-process `positronic` and `letta` backend kinds.
The Gnostic host has no PositronicKit dependency. The standalone reference
Runtime uses PositronicKit 7. The host targets Axoloty 1.x and uses it only
between Gnostic Nodes.

Release acceptance requires the structural work in #602, the schema migration
in #642, Axoloty alignment and the two-Node journey in #643, and the review,
soak, and owner acceptance gates in #552. The distributed journey proves that
one Node owns the Timeline, a Runtime executes through ACP, a remote Workspace
call crosses the gateway, and the journal survives restart. A release claim
requires recorded command results and peer versions. The required `make`
checks are listed in `AGENTS.md`.

### Deferred work

The following work is outside the v0.5 contract:

- Gnostic Agent or Profile primitives;
- cross-Runtime context handoff, prompt seeding, and model-context continuity;
- automatic Runtime installation or updates;
- operating-system sandboxing and container isolation;
- research consumers, inner experiments, and mandatory host research coupling;
- automatic Timeline failover, replicated authority, and leader election;
- Runtime subagents as child Timelines and automatic lineage tracking.

Each item needs an owning issue before it becomes release work.

### Invariants

- Each Timeline has one owning Node and one authoritative durable journal.
- A Runtime session cannot redefine, erase, or silently replace Timeline
  history.
- The host communicates with every Runtime through ACP v2 over stdio.
- ACP v1 is rejected. ACP v2 is an opt-in preview in 0.5.x.
- A Timeline has at most one active foreground Turn. A distinct concurrent Turn
  is rejected before prompt insertion.
- An admitted Turn sends at most one `session/prompt`. Retries with the same
  `clientTurnID` and digest recover its state.
- Every ACP v2 update is journaled as received, including `_meta` and unknown
  update kinds.
- Journal admission is durable before dispatch. A corrupt committed prefix
  quarantines the Timeline.
- A Project change creates a new Session record on the same Timeline and makes
  no claim of model-context continuity.
- Every Workspace invocation made through the gateway passes authorization at
  the Workspace-owning Node.
- Axoloty provides discovery and routing. It does not provide Gnostic identity,
  Timeline authority, journal durability, or Workspace authorization.
- No host target has PositronicKit in its transitive dependency closure. Only
  the standalone PositronicKit reference Runtime executable may depend on it.
- No Gnostic-owned v0.5 wire type, operation, or manifest key names an
  Ascendant or Agent primitive.
- No Gnostic test or release gate claims OS filesystem isolation.

## Rejected alternatives

- **Keep the special Axoloty Node for the PositronicKit Runtime.** The
  standalone ACP process already has a local stdio boundary. A special Node
  adds Axoloty and MQTT to a process that needs neither.
- **Link PositronicKit into the Gnostic host.** That couples host releases to
  the reference implementation and breaks the dependency firewall.
- **Add a Gnostic-only local process protocol.** ACP v2 already defines the
  process boundary. A second protocol would duplicate lifecycle and payload
  rules.
- **Queue a second Turn while the first runs.** Runtime-side queue semantics
  are not a contract. Rejecting before insertion gives the client a truthful,
  retryable result.
- **Infer idle after a quiet period.** Silence does not prove that the Runtime
  is idle. Gnostic uses reported state and treats uncertainty as uncertainty.
- **Rebuild another Runtime's context from the Timeline.** ACP does not define
  history import, and Timeline events do not represent the model's full
  reasoning state.
- **Move Timeline authority after Node failure.** Without a consensus or
  replication protocol, automatic transfer risks two writers and divergent
  journals.
- **Migrate old execution history as part of configuration migration.** The
  record formats and session state do not have a verified conversion. v0.5
  migrates operator configuration only.

## Dependency impact

This ADR adds no package dependency. Its implementation contract is delivered
through these issues:

- #572 owns the ACP v2 wire model.
- #604 removes PositronicKit from the host dependency closure.
- #605 owns the durable Timeline journal and recovery.
- #606 owns gateway-mediated Workspace calls.
- #609 and #610 deliver the standalone PositronicKit 7 reference Runtime.
- #611 removes legacy in-process backend kinds and old execution paths.
- #613 implements native Session resume and truthful recovery.
- #629 implements the Timeline Turn envelope and protocol major increment.
- #631 supervises local Runtime processes and probes ACP v2 capabilities.
- #632 tests ACP v2 conformance, replay, and failure recovery.
- #641 implements local and scratch Projects and Session `cwd` transitions.
- #642 migrates operator configuration without converting execution history.
- #643 validates Axoloty routing and the two-Node journey.
- #552 owns release review, soak, and owner acceptance.

## Consequences

- Gnostic owns durable Timeline identity. Runtime sessions are replaceable
  execution state.
- Every Runtime implementation follows one ACP v2 stdio contract. The
  PositronicKit reference Runtime is not a special Gnostic Node.
- Project changes keep Timeline identity but start a new Runtime Session. The
  client must not infer that model context continued.
- 0.5.0 breaks the prior wire contract once and migrates operator configuration
  explicitly. It abandons historical execution data without deleting the old
  files.
- Axoloty remains necessary for multi-Node routing, but it is not in a local
  Runtime's process loop.
- The stable host does not require research modules or PositronicKit.

## Fitness checks

The implementation issues must enforce these assertions:

- The dependency closure test fails if any host or host test target depends on
  PositronicKit. Only the standalone reference Runtime target may import it
  (#604).
- The ACP conformance test rejects v1 handshakes and checks the opt-in v2
  preview path (#572, #632).
- The source and wire fitness test rejects Gnostic-owned `Ascendant` and `Agent`
  identity names (#629).
- A distinct Turn submitted during an active Turn returns `-32001` before the
  Runtime sees `session/prompt`; a same-ID retry does not dispatch a duplicate
  prompt (#629, #632).
- Journal tests prove write-before-dispatch, exact ACP update preservation,
  epoch divergence detection, torn-tail recovery, checksum quarantine, and
  format-version rejection (#605, #632).
- Session tests prove native resume with the original `cwd`, ambiguous-state
  handling, and a new Session after a Project change without synthetic context
  seeding (#613, #641).
- Two-Node tests prove remote Turn routing and gateway Workspace authorization,
  and prove that owner loss does not transfer Timeline authority (#643).
- `make docs-check` checks this ADR, its links, the index, the glossary, and the
  compatibility declaration. `make verify` and `git diff --check` pass.

## Reconsideration triggers

- ACP v2 becomes stable or changes its required session lifecycle.
- A supported Runtime or client cannot use the ACP v2 preview and the release
  needs another interop contract.
- A concrete use case requires Gnostic-owned Agent or Profile identity.
- ACP defines safe history import and Gnostic can describe what context is
  preserved or lost.
- Runtime isolation changes the stated operating-system trust boundary.
- Axoloty adds a consensus or replication contract that can preserve one
  Timeline writer across owner loss.
- A research experiment needs host integration rather than an independent
  Runtime or consumer.

## Links

- [#640 — ADR 0021 owner issue](https://github.com/phynics/Gnostic/issues/640)
- [Epic #602 — ACP-first architecture](https://github.com/phynics/Gnostic/issues/602)
- [Epic #551 — Gnostic 0.5.0 release](https://github.com/phynics/Gnostic/issues/551)
- [ADR 0017 — ACP-first host and PositronicKit firewall](0017-acp-first-host-and-harness-agent.md)
- [ADR 0018 — Gnostic primitives after the ACP pivot](0018-gnostic-primitives-after-the-acp-pivot.md)
- [ADR 0019 — ACP v2 protocol baseline](0019-acp-v2-protocol-baseline.md)
- [ADR 0020 — Timeline-first primitives](0020-timeline-first-primitives.md)
- [Epic #140](https://github.com/phynics/Gnostic/issues/140)
- [RESET-001 #145](https://github.com/phynics/Gnostic/issues/145)
