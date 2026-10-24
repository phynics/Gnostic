# Building an experiment on the platform kit

`GnosticKit` is the backend-neutral platform kit from [ADR 0013 — Gnostic as an
experimentation platform](../Architecture/ADRs/0013-experimentation-platform.md).
It owns the parts every experiment shares: the model seam and metering, frozen
scenario cases, a deterministic driver, assertion scoring, run records and
manifests, the resumable runner and spend guard, and the shared
planted-obligation fixtures.

The kit depends on `GnosticCore` only. It imports no backend. The architecture
fitness check keeps `GnosticCore`, `GnosticHost`, and `GnosticCLI` free of
direct or transitive Kit and RLM dependencies. The isolated
`GnosticExperimentCLI` target owns those dependencies; the host's
`gnostic experiment` command forwards to that executable.

This chapter covers the optional experiment-kit contract. It is not a host
module extension API. The RLM scenario glue lives in
`Sources/GnosticExperimentCLI/`.

## What you build

A module contributes four things:

| Piece | Kit seam |
| --- | --- |
| A **driver** that executes one case and returns a run record | `ExperimentScenarioDriver` |
| A **model transport** that carries the prompts the driver sends | `ExperimentModelTransport` |
| A **case loader** that freezes scenario text to an approved digest | `ExperimentScenarioCaseSet` |
| A **run record** that names the Regime and its metrics | `ExperimentRunRecord` |

The kit names none of your Runtime types. Provider-specific model loops run in
independent ACP Runtime processes. The old in-process model bridge was removed
with the legacy host composition in #611. The current RLM live scenario command
remains unavailable until its outer-consumer work has an owner and implementation
(#624).

## Scenarios and frozen cases

One case is an `ExperimentScenarioCase`: an `id`, a `prompt`, a `reference`
answer, and the `evidencePaths` a correct answer should cite.

A case set is Markdown. `ExperimentScenarioCaseSet.parse(_:)` reads `## <id> —`
sections with three fields:

```markdown
## Q1 — Where does the broker listen?

**Question.** Which port does the broker listen on?

**Evidence.** `Sources/GnosticCore/Node.swift`.

**Reference answer.** The broker listens on port 8317.
```

The parser joins and collapses whitespace, drops inline-code delimiters, and
takes `evidencePaths` from the inline code spans that contain `/`.

Freeze the file by digest. `ExperimentScenarioCaseSet.load(from:expectedSHA256:)`
reads the file, SHA-256s the raw bytes with `ExperimentDigest`, and throws
`ExperimentError.caseSetChanged` when the file no longer matches. Pin the
approved digest as a constant next to the loader, as
[`RLMScenarioQuestionSet`](../../Sources/GnosticExperimentCLI/Experiment/RLMScenarioQuestionSet.swift)
does. A changed case set needs a new manifest version, not a silent rerun.

## Drivers

`ExperimentScenarioDriver` is the contract the runner uses:

```swift
public protocol ExperimentScenarioDriver: Sendable {
    var cases: [ExperimentScenarioCase] { get }
    var arms: [String] { get }
    func run(_ scenarioCase: ExperimentScenarioCase, key: ExperimentRunKey) async -> ExperimentRunRecord
}
```

`ScriptedScenarioDriver` is the deterministic driver for offline runs. It
returns a fixed answer per case and scores it with assertions, so it contacts
no provider and is safe in `make verify`. Use it for a harness gate and any
offline baseline.

A live driver owns its backend glue. It builds the case prompt, runs the
system under test, and maps the result onto an `ExperimentRunRecord`: outcome,
failure category, answer, evidence, wall time, metrics, usage, and cost. The
previous in-process RLM driver has moved to the transitional composition and is
not available through the clean host until its ACP Runtime replacement lands.

## The model seam

The kit meters, scripts, and records through one narrow protocol:

```swift
public protocol ExperimentModelTransport: Sendable {
    func generate(prompt: String, tier: ExperimentModelTier) async throws -> ExperimentGeneration
}
```

`ExperimentGeneration` carries the text and the provider-reported prompt and
completion tokens, or `nil` when the provider reported none.

- `ScriptedExperimentModelTransport` replays a fixed script. It proves the
  harness mechanics and never touches a provider.
- `RecordingExperimentModelTransport` wraps another transport and records every
  call, so a scripted, replayed, or live run is captured the same way.
- `ExperimentMeteredModel` wraps a transport with `ExperimentUsage`. A call
  whose provider reports no usage increments `callsWithoutUsage`, and the run's
  cost is then a lower bound (`costComplete == false`).

Tiers are the kit's own `primary`, `utility`, and `fast`. A backend adapter maps
its native tier onto them; see `PositronicContributionModelServiceAdapter`.

## Scoring

Scoring is deterministic and assertion-based. There are no similarity metrics.

- `ExperimentObligation` is the class a check tests: `fact`,
  `negative-constraint`, `exact-value`, `supersession`, `correction`,
  `open-item`, `tool-evidence`, `back-reference`, `concurrent-root`,
  `malicious-tool-text`, and `self-maintenance`.
- `ExperimentAssertion` is the check itself: `contains`, `containsNormalized`,
  `containsAll`, `absent`, or `equals`.
- `ExperimentScenarioCheck` binds an ID, an obligation, a description, and an
  assertion.
- `ExperimentAssertionScorer` returns one `ExperimentCheckResult` per check, and
  `ExperimentScore.recallByObligation` reports recall per class rather than one
  opaque number.

A live round is scored after collection. `ExperimentBlindRating` builds a sheet
keyed by an opaque ID that hides the arm, and `apply(_:to:)` refuses unknown
IDs and out-of-range scores so a mangled evaluator reply cannot be
half-applied. The 0–10 rating rule is the kit's.

## Run records and the Regime

`ExperimentRegime` is the value from `CONTEXT.md`: backend kind, selected
modules and their versions, model tiers, provider, endpoint, and policy fields.
The run manifest records it with the fixed parameters that make a round
reproducible: the repository commit, the pinned image digest, the host, the
sampling parameters, the budget, the frozen case-set digest, the corpus
revision, the selected cases and arms, the repetitions, and the pricing.

`ExperimentRunRecord` is one result: the case, arm, and repetition; the
outcome; a structured failure category; the answer and cited evidence; the
Regime's named metrics; the root and leaf `ExperimentUsage`; and the cost.
`ExperimentRunMetrics` is a free-form `[String: Double]`, so a new experiment
adds metrics without a schema change.

`ExperimentBudget` bounds wall time, model calls, estimated tokens, and any
extra counters. `ExperimentCeiling` turns a budget and a pricing card into the
worst case before any spend. `ExperimentArtifactFile` reads and writes the
resumable round artifact as JSON, with a trailing newline.

## The runner and the spend guard

`ExperimentPlan` orders the runs: case, then repetition, then arm, so a round
that stops early still holds paired observations.

`ExperimentRunner` resumes a matching artifact, runs only what is missing,
persists after every run, and stops before a run that could cross the
authorised cost ceiling. A completed pilot carries an `ExperimentProjection`,
and `ExperimentArtifactFile.authorisingPilot` refuses a matrix whose fixed
parameters differ from its pilot (the void-round rule).

The spend guard has two required halves for a live round:

- `--confirm-spend` is the consent to contact a provider. Without it the
  command prints the plan and the worst-case ceiling, runs the preflight, and
  stops. No provider is contacted.
- `--max-cost` is the ceiling for a priced round. A priced round refuses
  `--confirm-spend` without a positive ceiling.

Pass `--input-price`, `--output-price`, and `--prices-date` together, or none
of them for a flat-rate subscription. `make scenario-live-preflight` proves the
dry-run path end to end without spending.

## Shared planted-obligation fixtures

`ExperimentFixtureLibrary.plantedObligations` is the single source for the
planted obligations shared by Context (#437) and Ouroboros (#476). It covers
every `ExperimentObligation`, carries the checks a correct answer passes, and
overloads a deliberately small context window: the
`HarnessGateTests.fixturesOverflowSmallWindow` proof shows the fixture text
exceeds a 128-token window, which Context's small-window baseline needs.

Use the fixtures directly, or overload them: a consumer can map a fixture to
its own `ExperimentScenarioCase` and run its own arms over the same text. Do
not copy the list into another target; that breaks the single-source rule the
registry and the harness gate depend on.

`ExperimentFixtureLibrary.driver()` builds a deterministic driver over the
whole set. The harness gate in
[`Tests/GnosticKitTests/HarnessGateTests.swift`](../../Tests/GnosticKitTests/HarnessGateTests.swift)
runs inside `make verify` and asserts every fixture passes its checks, a
degraded answer fails, every class is covered, and a scripted round completes
with no provider.

## Generic commands

`gnostic experiment` forwards to the separately packaged `gnostic-experiment`
executable, installed beside `gnostic` or on `PATH`. Experiment commands remain
separate from a Node.

```sh
gnostic experiment replay --trace Documentation/Experiments/<file>.trace.json
gnostic experiment rlm-scenario-rating --artifact <file.json> --write-sheet <sheet.json>
```

`replay` checks a recorded tape against the built-in harness without provider
contact. `rlm-scenario-rating` exports or applies blind scores for an existing
RLM artifact. The RLM live scenario remains an error because its in-process
model path was retired; the isolated executable does not restore host model
execution or the deferred gateway tool (#615).

## Trace and replay

A Run can record a **trace**: model requests and responses, tool calls and
results, and the outcome, in order and correlated to a Turn. The tape also
records the Run's full `ExperimentRegime` (schema version 2), so replay names
the same Regime as the run record instead of a fixed label. Recording is
opt-in by construction. Nothing records unless a caller builds an
`ExperimentTraceRecorder` and wraps a transport or tool executor with
`TracingExperimentModelTransport` or `TracingExperimentToolExecutor`. The tape
holds payloads only because that wrapper is present; there is no global switch
and no production default.

`ExperimentTraceFile` writes the tape as deterministic JSON with sorted keys
and a trailing newline. `ExperimentTrace.digest()` is the SHA-256 of that
canonical JSON, so a tape is content-addressable across hosts.

A Run can also journal its tape durably. `ExperimentTraceRecorder.enableJournal(at:)`
writes each event through the kernel's append-only log, recovers a partial tape
after a crash, and continues its current Turn. Journaling is opt-in like
recording itself: a recorder without a journal keeps its in-memory tape.

Replay substitutes recorded model responses for live calls.
`ExperimentReplay.replay(_:using:)` runs a harness over the tape, records what
the harness actually did, and reports divergences. A changed prompt, a changed
tier, an exhausted tape, a changed tool step, or a changed outcome is a
divergence, never a silent pass. Replay contacts no provider.

The built-in `kit replay-self-check` harness replays the committed fixture
`Documentation/Experiments/kit-replay-self-check.trace.json` inside
`make verify`. After an intentional harness change, regenerate the fixture with
`gnostic experiment replay --trace <path> --record` and commit the result; the
`recordedMatchesFixture` test fails while the committed fixture is stale.

## Consumer handoff

The kit is the handoff target for the first two consumers:

- **Context (#437)** builds its three baselines on `ScriptedScenarioDriver`,
  `ExperimentAssertionScorer`, `ExperimentRunRecord`, and the shared fixtures.
  Its baselines record no live provider.
- **Ouroboros (#476)** uses the shared planted-obligation fixtures and harness
  gate for its deterministic gate in `make verify`, and `experiment run` with
  the spend guard for its recorded live rounds.

The regime/run surface and the payload-free instrumentation hooks are the
handoff points to the CLI console (#463) and the module instrumentation issues
(#492 Ouroboros, #493 Akasha).

## Runtime-owned model loops

The host does not expose Kit interceptors or module hooks to ACP Runtimes.
Ouroboros, Akasha, context compilation, and Atlas remain parked design
references. An experiment that needs to alter a model loop must implement an
independent ACP Runtime; an outer consumer uses the public `GnosticClient`
products over Axoloty. Neither path adds experiment dependencies to the host.

## Validate your change

Run `make verify` for the harness gate and `make docs-check` for documentation
and links. A behavior change needs a failing behavioral test at the public
seam; a new experiment should name its gate from the validation table in
[`AGENTS.md`](../../AGENTS.md).
