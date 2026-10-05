# Building an experiment on the platform kit

`GnosticKit` is the backend-neutral platform kit from [ADR 0013 — Gnostic as an
experimentation platform](../Architecture/ADRs/0013-experimentation-platform.md).
It owns the parts every experiment shares: the model seam and metering, frozen
scenario cases, a deterministic driver, assertion scoring, run records and
manifests, the resumable runner and spend guard, and the shared
planted-obligation fixtures.

The kit depends on `GnosticCore` only. It imports no backend.
`CompositionArchitectureFitnessTests.kitDependencyBoundary` fails the build if
`GnosticKit` gains a `PositronicKit`, `PKContracts`, module, or composition
dependency, so P7 can extract Positronic from Core without touching the kit.

This chapter covers the contract a module implements. The RLM scenario
(`Sources/GnosticCLI/Experiment/`) is the worked in-tree consumer.

## What you build

A module contributes four things:

| Piece | Kit seam |
| --- | --- |
| A **driver** that executes one case and returns a run record | `ExperimentScenarioDriver` |
| A **model transport** that carries the prompts the driver sends | `ExperimentModelTransport` |
| A **case loader** that freezes scenario text to an approved digest | `ExperimentScenarioCaseSet` |
| A **run record** that names the Regime and its metrics | `ExperimentRunRecord` |

The kit names none of your backend types. Bridge them at the composition layer,
as [`GnosticHost/ExperimentModelAdapters.swift`](../../Sources/GnosticHost/ExperimentModelAdapters.swift)
does for Positronic.

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
[`RLMScenarioQuestionSet`](../../Sources/GnosticCLI/Experiment/RLMScenarioQuestionSet.swift)
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
RLM driver (`ExperimentCommands.swift`) shows the shape: it runs the engine,
meters the root and leaf model roles, and records a structured failure category.

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

`gnostic experiment` is the shared surface. Every run is opt-in and separate
from a Node.

```sh
gnostic experiment run <module> <scenario> --regime <ascendant-uuid>
gnostic experiment replay --trace Documentation/Experiments/<file>.trace.json
gnostic experiment export --artifact Documentation/Experiments/<file>.json
```

`run` resolves the `(module, scenario)` pair through a CLI-owned catalog. The
built-in `kit self-check` scenario runs offline with scripted models and
assertion scoring. A live scenario names `--regime`, the Positronic Ascendant
whose provider and models it uses, and follows the spend guard above. `replay`
replays a recorded tape against the built-in harness with no provider contact.
`export` prints any round artifact as machine-readable JSON.

A module can also contribute its own experiment subcommand through its
descriptor, as `rlm-scenario` does. That command still consumes the same kit
runner, artifact, metering, scoring, and spend guard; only the backend glue
stays with the module.

## Trace and replay

A Run can record a **trace**: model requests and responses, tool calls and
results, and the outcome, in order and correlated to a Turn. Recording is
opt-in by construction. Nothing records unless a caller builds an
`ExperimentTraceRecorder` and wraps a transport or tool executor with
`TracingExperimentModelTransport` or `TracingExperimentToolExecutor`. The tape
holds payloads only because that wrapper is present; there is no global switch
and no production default.

`ExperimentTraceFile` writes the tape as deterministic JSON with sorted keys
and a trailing newline. `ExperimentTrace.digest()` is the SHA-256 of that
canonical JSON, so a tape is content-addressable across hosts.

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

## Validate your change

Run `make verify` for the harness gate and `make docs-check` for documentation
and links. A behavior change needs a failing behavioral test at the public
seam; a new experiment should name its gate from the validation table in
[`AGENTS.md`](../../AGENTS.md).
