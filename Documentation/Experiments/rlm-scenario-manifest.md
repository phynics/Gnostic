# RLM scenario manifest — #354

Status: **Pre-registered.** The dual-executor amendment to ADR 0012 landed with
#350, and §2 below is the only slot it parameterised; this revision records that
alignment. v7 records the owner's choice of a light sample (§1, §0 G2, §8),
made before any live run. The other pre-registered rules are unchanged.

Author: consultant session 3ed79195 (session ended; preserved by coordinator f9746017).
Version: **v7**. Revised after four rounds of coordinator review (session f9746017),
one amendment-alignment pass for #350, and one owner sample-size decision.
Intended destination: `Documentation/Experiments/rlm-scenario-manifest.md`.

---

## 0. What returns a second `CONTINUE_EXPERIMENT`

Pre-registered, before any measurement is taken, so that this outcome is a
recognised result rather than something the epic backs into.

The gate returns `CONTINUE_EXPERIMENT` if **any** of the following hold at
decision time:

- **G1 — Missing required evidence.** Any row in §4 marked `required` has
  status `unavailable`. ADR 0012 names these explicitly; an absent row is not
  a partial result.
- **G2 — Insufficient completed sample.** Fewer than 80% of the questions run
  in the round produce a completed run on either executor, at the round's
  recorded repetitions. A run that terminates on a run-terminal failure is not a
  completed run. (v7: was 10 of 12 at 3 repetitions each.)
- **G3 — Untrustworthy scoring.** Inter-rater agreement on the quality rubric
  (§5) falls below κ = 0.6, or a single evaluator scored the whole set with no
  second rater on at least 20% of runs.
- **G4 — Confounded repair rate.** Executor repair rates (§4, M6) differ by
  more than 10 percentage points **and** the difference is attributable to a
  known unfixed defect in the #334 / #351 class rather than to the executor.
  A confounded measurement is not evidence about the executor.
- **G5 — Containment escape.** Any malicious-program, heap, or loop fixture
  escapes the **outermost** bound on either executor during the matrix — the
  parent wall deadline, the rlimit set, or the process boundary. Promotion
  cannot proceed past an unbounded containment result.

  G5 is deliberately scoped to the outermost bound, **not** to per-cell bounds.
  Chibi is known to lack per-cell time and allocation limits (#352): a looping
  cell there runs to the parent wall deadline, which then terminates the worker.
  That is a recorded containment *difference*, measured by M12 and ranked by the
  §6 tiebreak. It is not an escape, and it must not trip G5 — a G5 written
  against per-cell bounds would trip on a known, documented gap and pin the gate
  to `CONTINUE_EXPERIMENT` permanently, which is the failure mode §0 exists to
  prevent.

It does **not** return `CONTINUE_EXPERIMENT` merely because the two executors
score alike. That case is resolved by the tiebreak in §6, because "they are
equivalent" is a finding, not an absence of one.

### The anti-loop rule

`CONTINUE_EXPERIMENT` has already been returned once, by #181. **If this gate
returns it a second time, #175 does not schedule a third evidence round.** It
escalates to an explicit, owner-level choice between:

- **fund** — commit the named missing evidence as scheduled, budgeted work. This
  requires **all three** of: a named owner, a fixed date, and an explicit list of
  the evidence rows being funded. A `fund` decision missing any of the three is
  not a `fund` decision.
- **archive** — retire the RLM experiment under ADR 0012's `ARCHIVE` outcome and
  close #180, #355 and the remaining children with the recorded rationale.

**Terminal fallback, pre-registered.** If the funded round also fails to produce
a decision, the outcome is `ARCHIVE`. No further fork is offered and no third
round is scheduled.

Rationale: an experiment that can return "continue" indefinitely has no
termination condition and will consume effort without ever producing a decision.
Two rounds is the budget. Without the terminal fallback, `fund` is a third round
with paperwork — it ends the sequence of things called rounds without ending the
loop, and the decision to continue then gets made under sunk cost rather than
against a rule fixed in advance. That is precisely why the fallback is
pre-registered here rather than left to judgement at the time.

**On counting #181 as the first round.** It is counted, although it never ran
this manifest and was a one-run smoke against a weaker gate. The argument that it
should not count is the argument that makes epics immortal: every prior round is
retrospectively "not a real round." Recorded here so it is not relitigated.

---

## 1. Fixed parameters

Identical across every run, every executor, every repetition. Changing any of
these invalidates the matrix and starts a new manifest version.

| Parameter | Value |
| --- | --- |
| Manifest ID | `rlm-scenario-manifest-v1` |
| Corpus | One pinned Gnostic repository snapshot, recorded by commit SHA |
| Corpus scope | `Sources/GnosticCore/Runtime`, `Sources/GnosticRLM`, `Documentation/Architecture` |
| Questions | 12, fixed, recorded verbatim in the manifest artifact (§7) |
| Repetitions | 1 per question per executor by default, at most 3 (v7); recorded per round |
| Provider / model family | One family, pinned by exact model ID, root and leaf both recorded |
| Root iteration budget | Fixed, identical per executor |
| Leaf call budget | Fixed, identical per executor |
| Token limit | Fixed, identical per executor |
| Wall deadline | Fixed, identical per executor |
| Heap / rlimit set | Per executor as configured; recorded, not varied within the matrix |
| Cost accounting | Provider-reported tokens; monetary figures at the rates in effect on the run date, recorded |

Questions must be representative Gnostic questions of the kind ADR 0012
requires — real architecture and runtime questions over this repository, not
the four-file synthetic fixture used by `bounded-repository-fixture-v1`.

## 2. Executor matrix

ADR 0012 now offers Guile and Chibi as first-class, selectable executors behind
one seam and removes bounded retrieval from the required comparison set. The
matrix is therefore:

| Arm | Executor | Speculation | Status |
| --- | --- | --- | --- |
| A | Guile | off | required |
| B | Chibi | off | required |
| C | scripted engine | off | required, deterministic control |
| D | ordinary Positronic Workspace analysis | n/a | required if available; see M8 |
| E | bounded retrieval | n/a | unavailable — removed from the required set by the ADR 0012 amendment |

Arms A and B run the identical manifest. Arm C is the existing deterministic
harness and anchors the live runs to the repository gate. Speculation is out of
scope here entirely — #180 owns it, and under the wording now in #180 its
baseline is the speculation-off arm of whichever executor #354 makes default.

Arm E is recorded as unavailable rather than skipped: the ADR amendment removes
it from the required set because no implementation exists and none is scheduled.
If bounded retrieval is ever implemented, it re-enters the comparison with the
same manifest and model family as the other arms.

## 3. Measurement tiers

Per the constraint that spend is visible before it is committed:

- **`deterministic`** — runs in the pinned container, no credentials, no spend.
  Reproducible by any reviewer.
- **`environment`** — no provider spend, but requires a host the CI gate may not
  have (macOS). Reproducible only where that host exists.
- **`live-budget`** — requires provider credentials and spends money. **Every
  such row must carry a projected call count, token count and monetary figure
  from the Stage 0 pilot (§8) before the full matrix is authorised.**

## 4. Measurements

| ID | Measurement | Tier | Required | Source |
| --- | --- | --- | --- | --- |
| M1 | Worker startup ms | deterministic | required | existing harness |
| M2 | Evaluation ms | deterministic | required | existing harness |
| M3 | Cancellation latency ms | deterministic | required | existing harness |
| M4 | Sampled peak RSS / CPU | deterministic | required | `/proc/<pid>` sampling, existing harness |
| M5 | Semantic result digest parity | deterministic | required | existing harness |
| M6 | Generated-cell repair rate | deterministic | required | `RLMRunMetrics.repairs`, `.rootCellRejections`, `.runtimeFailures`, `.resourceFailures` (#349) |
| M7 | Answer quality + evidence correctness | **live-budget** | required | rubric, §5 |
| M8 | Ordinary Positronic analysis comparison | **live-budget** | required if arm D available | same questions, no RLM tool |
| M9 | Root/leaf calls, tokens, monetary cost | **live-budget** | required | provider telemetry + `RLMRunMetrics` |
| M10 | End-to-end latency per question | **live-budget** | required | wall clock per run |
| M11 | Malicious-program fixture outcomes | deterministic | required | #178 / #179 suites, aggregated |
| M12 | Heap / loop / recursion containment | deterministic | required | #352 stress fixtures |
| M13 | macOS containment matrix | environment | required | #353 |
| M14 | Packaging + bridge-maintenance burden | environment | required | #351/#353, scored per §5a |

M6 is newly measurable only because #349 feeds recoverable failures back to the
root model. Before #349, repair rate was structurally unmeasurable — any cell
error ended the run.

M11–M13 are the rows most likely to be `unavailable` at decision time, and
therefore the most likely trigger for G1. They are scheduled **first**, because
they cost no provider budget and they can veto the whole matrix.

### What satisfies M12 and M13 (pinned, so it is not discovered at decision time)

G1 asks whether an evidence row is **available**, not whether the platform is
fully supported. The distinction decides how hard the #352 and #353 dependencies
are:

- **M12 is satisfied** when the stress fixtures have *run* on both executors and
  their outcomes are recorded. A recorded per-cell containment gap on Chibi is a
  measured result, not an absent one — it feeds the §6 tiebreak. M12 is
  `unavailable` only if the fixtures were not run.

  **M12 records three outcome classes per fixture, not two.** This is required by
  the G5 loosening: once G5 vetoes only outermost-bound escapes, the tiebreak
  becomes the sole place the Chibi per-cell gap registers, and a two-class
  recording would delete the signal rather than relocate it.

  | Class | Meaning |
  | --- | --- |
  | `contained` | The fixture was bounded at cell granularity; the worker survived and the next cell ran in the same worker. |
  | `worker-fatal` | The fixture was bounded only at the outermost bound; the worker was terminated and the run's state was lost. Not an escape — the bound held, at coarser granularity. |
  | `escaped` | No bound held. Trips G5. |

  Tiebreak criterion 1 (§6) ranks executors on the **distribution across these
  three classes**, not on a binary contained/escaped verdict. An executor whose
  fixtures are `contained` ranks above one whose equivalent fixtures are
  `worker-fatal`, and that difference is exactly what G5 no longer vetoes.
- **M13 is satisfied** when #353's containment matrix exists and every Linux
  guarantee is either proven on macOS **or recorded as a bounded gap** — which is
  #353's own acceptance wording. Full macOS parity is not required to clear G1.
  M13 is `unavailable` only if no macOS matrix was produced at all.

So #352 and #353 must **land**, but they may land with bounded, recorded gaps and
still clear G1. What does not clear G1 is either issue not running.

### §5a — What M14 scores, and what it must not

M14 is the only qualitative row, which makes it the row most vulnerable to
scoring whatever is most recent and most vivid. It is bounded as follows.

**In scope — structural properties of the artifact and the bridge, as they stand
at the §6 freeze date:**

- build flag set, its size, and how much of it is non-default patching;
- packaging steps and their reproducibility, including recorded hashes;
- platform coverage and how it is obtained;
- pinning and upgrade burden — what breaks when the interpreter version moves;
- **coupling between worker correctness and interpreter build configuration** —
  that is, whether changing a build flag can silently break the wire layer.

**Out of scope — explicitly not score inputs:**

- counts of defects found in worker code. Those are measured by M5 (digest
  parity) and M12 (containment), where they are observed rather than judged;
- when a defect was discovered, or how recently;
- the history of how the artifact reached its freeze-date state.

**Two reasons the exclusions are firm, not stylistic.**

*Detection bias.* Defects are found where we look, and we do not look evenly. The
#351 spike probed a Chibi build-flag change; no equivalent flag-change spike was
run against Guile. Scoring discovered defects would therefore encode "we
investigated Chibi harder" as "Chibi is worse," which is a statement about our
attention, not about the executor. #354's independent method review should be
expected to catch this if the manifest does not prevent it.

*Freeze-date state, not journey.* §6 already scores containment and platform
completeness as of a declared freeze date. M14 is scored the same way, for the
same reason. A defect fixed before the freeze date is not a burden at the freeze
date; it is history.

The distinction that survives both exclusions is **event versus structure**. "A
latent framing bug was found in one worker" is an event and is out of scope. "This
worker's wire correctness is coupled to an interpreter build flag" is a structural
property, is durable, and is in scope — while it remains true. Once a fix closes
the coupling, the structural property is gone and M14 scores its absence, not the
memory of it.

## 5. Scoring rubric

Per question, per run. Scored blind to which executor produced the answer.

| Dimension | Scale | Note |
| --- | --- | --- |
| Answer correctness | 0–3 | against a reference answer fixed before runs |
| Evidence correctness | 0–3 | every returned reference resolves in the snapshot and supports the claim |
| Evidence sufficiency | 0–2 | material claims are covered by a reference |
| Unsupported assertion | penalty | any claim with no resolvable evidence |

Reference answers and rubric are frozen before any live run.

**v7 replacement (owner decision).** The rounds under v7 use one score per
completed run, 0 to 10, assigned after collection by an LLM evaluator. The
evaluator sees the question, the reference answer, the answer, and its cited
evidence, but not the executor. The dimensions above, the mechanical scoring
below, and the κ condition in G3 do not apply to v7 rounds; the result is a
single-evaluator, model-rated claim.

### Mechanical scoring first

**Evidence correctness and evidence sufficiency are scored mechanically**, with
no rater: a reference that does not resolve against the pinned snapshot is an
automatic zero. The tool already validates references before returning them, so a
non-resolving reference is a defect finding rather than a quality finding, and is
reported separately.

This is load-bearing for the gate's independence from rater supply. Two of the
four rubric dimensions need no human, and the executors can be separated on those
alone if they differ there.

### Rater type — must be named before Stage 2

**Only `answer correctness` requires judgement.** The manifest requires that the
rater type be recorded explicitly, and only two are admissible:

- **Human raters (preferred).** Two raters on at least 20% of runs, drawn across
  both executors, giving the κ ≥ 0.6 condition in G3. This is roughly 15+
  double-scored runs at the §1 matrix size. **A named person must own this before
  Stage 2 is authorised.**
- **Model-based raters (fallback).** Permitted, but κ between two instances of
  the same model family is not a meaningful agreement statistic and must not be
  reported as one. If raters are model-based, **G3 is replaced**, not weakened:
  the gate drops κ, leans on the mechanical dimensions above, and adds blind
  pairwise preference with a recorded disagreement rate — reported explicitly as
  a weaker claim about answer quality than a human-rated result.

A κ threshold with no named rater supply is an unsatisfiable condition wearing a
number, and would trap the gate exactly as an unbuilt arm E would. Naming the
rater type is therefore a Stage 2 precondition, not a reporting detail.

## 6. Decision rule

1. If any G1–G5 condition holds → `CONTINUE_EXPERIMENT`, then the anti-loop
   rule in §0 applies.
2. Otherwise, if one executor's combined quality score exceeds the other's by
   more than the measured repetition noise band → that executor is the default.
3. Otherwise the executors are equivalent on quality, and the default is chosen
   on operational criteria **in this fixed order**:
   1. **Containment completeness** — per-cell time and allocation bounds
      enforced, runaway cell recoverable rather than worker-fatal (M12).
   2. **Platform coverage** — supported on both Linux and macOS with the
      containment guarantees proven or their gaps bounded (M13).
   3. **Packaging and maintenance burden** (M14).
   4. **Measured startup and RSS** (M1, M4).
4. The non-default executor is then explicitly kept or retired, with rationale.

The ordering in step 3 is deliberate and should be argued with before the runs,
not after. It ranks containment and platform coverage above the startup and RSS
figures on which Chibi currently leads, because a faster executor that loses the
whole run to a runaway cell is not the safer default. If the coordinator
disagrees, change it **now** — changing it after the numbers are in is
outcome-fitting.

### The tiebreak must not measure our own delivery schedule

Criteria 1 and 2 have a coupling that has to be priced explicitly, or the
tiebreak silently ranks project management rather than executors.

G5 already vetoes any containment *escape*. So by the time step 3 runs, neither
executor has escaped anything, and what criterion 1 actually discriminates on is
**per-cell** bounds — which is #352, and #352 is Chibi-specific. Criterion 2 has
the same shape with #353. Left unqualified, Chibi's score on the two top-ranked
criteria would be a function of whether #352 and #353 landed before the gate ran,
not of anything intrinsic to Chibi.

Two requirements close this:

- **Feature-freeze date.** Containment and platform completeness are scored **as
  of a declared freeze date**, recorded in the manifest artifact. Work landing
  after that date does not change the scores of this gate round.
- **Gap classification.** Every containment and platform gap is recorded as
  either:
  - **intrinsic** — it follows from the executor's design or its runtime, and no
    scheduled work closes it; or
  - **unimplemented** — a scheduled increment would close it, named by issue.

  The tiebreak ranks these differently and must say which it is ranking. An
  intrinsic gap is evidence about the executor. An unimplemented gap is evidence
  about our schedule, and a default chosen on one is a default chosen on when we
  happened to run the gate.

If, at the freeze date, a top-ranked criterion separates the executors **only**
by unimplemented gaps, that criterion is skipped and the tiebreak falls through
to the next one. The skip is recorded with its reason.

Skipping is the more aggressive option — weighting the criterion down would still
let a transient state decide, only less visibly. It is the right one here because
the amended #175 keeps both executors, so the default is a switchable
configuration rather than an architectural commitment; choosing it on a gap that
a scheduled issue would close bakes a transient state into a durable record.

An unqualified skip has its own failure mode: the gap never gets closed and the
skip quietly becomes permanent. Two conditions, pre-registered:

1. **A skip creates an obligation.** The skip is recorded together with the named
   issue that would close the gap. When that issue lands, the default decision is
   **re-evaluated against the skipped criterion alone** — not reopened wholesale
   — against the recorded tiebreak.
2. **A closed issue that did not fix the gap reclassifies it.** If the named issue
   is closed as won't-fix, retargeted, or closed stale without the gap being
   fixed, the gap **reclassifies from `unimplemented` to `intrinsic`**, and the
   skipped criterion re-enters the tiebreak at its original rank.

Condition 2 is what stops `unimplemented` from being a permanent free pass: a gap
is only excused while someone is actually scheduled to close it.

## 7. Reproducibility metadata

Recorded in the artifact for every run, extending the existing
`rlm-runtime-benchmark.json` schema rather than replacing it:

- `manifestID`, `schemaVersion`, `generatedAtUTC`, `gitCommit`
- `host`: OS, architecture, container image **digest** (not a tag)
- `executor`: name, interpreter version, build flag set, binary SHA256
- `model`: exact root and leaf model IDs, provider, sampling parameters
- `budgets`: root iterations, leaf calls, tokens, wall deadline, rlimits
- `questions`: verbatim, with reference answers by hash
- `measurements[]`: each with `status` ∈ `measured` | `unavailable` |
  `requires-live-budget`, and for `unavailable` a `reason` string
- `unavailableMeasurements[]`: retained from the existing schema
- `costProjection` and `costActual` for every live-budget row

The existing artifact's `status` / `unavailableMeasurements` pattern already
does the honest-reporting job. Extend it; do not invent a second schema.

### Runs execute against a pinned image digest, not a tag

Recording the digest after the fact establishes *what* ran. It does not establish
that the *intended* thing ran, and the difference is not theoretical: during the
#351 spike on 2026-09-22 a concurrent task's cached `make image` retagged
`gnostic-dev:latest` back to baseline mid-run, and the spike had to be re-run
against an explicit image ID.

This is a **validity threat to the comparison**, not only a reproducibility
concern. §1 requires that every arm run identical fixed parameters. If arms A and
B execute against different images, the artifact will faithfully record two
different digests, and the executors will appear to differ for a reason that is
actually image drift. The manifest would document its own invalidity rather than
prevent it.

Therefore:

- Every run is executed against an **explicit image digest or image ID**. A
  floating tag such as `gnostic-dev:latest` is not an admissible run target.
- The digest is **verified as a precondition of each stage**, not recorded only
  at the end. A live stage voided by image drift costs real money, so the check
  belongs before the spend, not in the post-mortem.
- If the digest differs across arms within one matrix round, **that round is void
  and re-run**. It is not reconciled, and its numbers are not compared.

This is a precondition rather than a G-condition: image drift means re-run the
round, not abandon the experiment.

## 8. Staging, so spend is visible before it is committed

**Stage 0 — deterministic rows.** M1–M6, M11, M12 in the pinned container. No
credentials, no spend. If G5 trips here, stop: no live budget is spent on a
matrix that cannot promote.

**Stage 1 — environment rows.** M13, M14 on macOS. No spend. If these come back
`unavailable`, G1 already holds and the live stage is pointless.

**Stage 2 — pilot.** One question, the round's repetitions, both executors,
live. This measures rather than estimates the per-run call count, token count
and cost, and projects the full matrix: questions × repetitions × 2 executors
(v7 default: 12 × 1 × 2 = 24 runs), plus arm D. **The projection is reported to
the coordinator and the full matrix is not authorised until the projected spend
is accepted.**

**Stage 3 — full matrix.** Only after Stage 2 is authorised. v7 lets the owner
run a named subset of the 12 questions; the artifact records which.

Staging in this order means the two cheapest stages can veto the expensive one,
and the expensive one is costed from measurement rather than guesswork.

## 9. Known bounds of this manifest

- It measures one provider family. It does not establish that the result
  generalises to another.
- 3 repetitions bound run-to-run nondeterminism weakly. The noise band in §6
  step 2 is computed from those repetitions and will be wide; a narrow quality
  difference will correctly fall through to the tiebreak.
- Arm E (bounded retrieval) is unavailable and stays unavailable. ADR 0012 lists
  it; no implementation exists. It is recorded as a permanent gap of this
  manifest version, not as a pending measurement.
- Qualitative rows (M14) are judgement recorded with evidence, not metrics.
- **Uneven attention is a bound on the whole manifest, not only on M14.** §5a
  excludes discovered-defect counts from M14 because defects are found where we
  look and we do not look evenly. The same bias reaches any row whose value
  depends on how hard each executor was probed — M5 digest parity, M11
  malicious-program outcomes, M12 containment. Every fixture in those rows must
  be **run against both executors**, and any fixture that exists for only one
  executor is recorded as a coverage gap rather than as a result about the
  executor that has it. Where probing effort was genuinely uneven — as with the
  #351 Chibi build-flag spike, which had no Guile equivalent — that asymmetry is
  recorded in the artifact alongside the affected rows, so the method review can
  see it rather than infer it.

---

## 10. Revision history

**v2** — revised after coordinator review. Five changes, four of them from
coordinator arguments:

1. §0 — `fund` now requires a named owner, a fixed date and an explicit evidence
   list, and a funded round that fails to decide falls back to `ARCHIVE` with no
   further fork. Without this, `fund` was a third round with paperwork.
   *(coordinator)*
2. §6 — added the feature-freeze date and the intrinsic-versus-unimplemented gap
   classification, so the tiebreak cannot rank our delivery schedule as if it
   were a property of the executors. *(coordinator)*
3. §4 — pinned what satisfies M12 and M13: #352 and #353 must land, but may land
   with bounded recorded gaps and still clear G1. *(coordinator)*
4. §5 — named the admissible rater types, made a named human owner a Stage 2
   precondition, moved evidence scoring explicitly to mechanical, and specified
   what replaces G3 if raters are model-based. *(coordinator)*
5. §0 — **G5 restated to the outermost bound.** As written in v1 it would have
   tripped on Chibi's known per-cell gap and pinned the gate to
   `CONTINUE_EXPERIMENT` permanently — the exact failure mode §0 exists to
   prevent. Surfaced while pricing argument 2. *(consultant)*

**v3** — second coordinator review. Two changes, both consequences of v2's G5
loosening rather than new ground:

6. §4 — M12 now records **three** outcome classes (`contained`, `worker-fatal`,
   `escaped`) and criterion 1 ranks on their distribution. Once G5 vetoes only
   outermost-bound escapes, the tiebreak is the sole place the Chibi per-cell gap
   registers; a two-class recording would have deleted that signal instead of
   relocating it. *(coordinator)*
7. §6 — the skip rule gains two conditions: a skip records the named issue that
   would close the gap and obliges re-evaluation of that criterion when the issue
   lands; and an issue closed without fixing the gap reclassifies it from
   `unimplemented` to `intrinsic`, returning the criterion to the tiebreak at its
   original rank. Without these, an unqualified skip becomes a permanent free
   pass. *(coordinator)*

The G5 finding in v2 item 5 was independently verified against
`Experiments/GuileRLMWorker/worker.scm:76-77` (per-cell time and allocation
limits) and `Sources/GnosticRLMChibi/RLMChibiWorkerSession.swift:190,197`
(wall-deadline wrap, worker termination on timeout).

**v4** — third coordinator review, prompted by the #351 build spike. Two changes:

8. §4/§5a — M14 bounded to structural properties of the artifact and bridge at
   the freeze date, with defect counts and discovery recency explicitly excluded.
   Adds the detection-bias argument: defects are found where we look, and the
   spike probed Chibi's flag set with no Guile equivalent, so scoring discovered
   defects would encode our attention as executor quality. Build-flag/wire-layer
   coupling stays in scope as a structural property while it remains true.
9. §7 — runs must execute against a pinned image digest, verified as a stage
   precondition; a round whose arms ran different digests is void and re-run.
   Prompted by an observed `gnostic-dev:latest` retag during the spike. This is a
   validity threat to the §1 identical-parameters requirement, not only a
   reproducibility concern. *(coordinator)*

**v5** — the detection-bias argument generalised out of §5a, per the
coordinator's observation that it reaches beyond M14. §9 now bounds the whole
manifest: every fixture in M5, M11 and M12 runs against both executors, a
single-executor fixture is a recorded coverage gap rather than a result, and
uneven probing effort is recorded in the artifact next to the rows it touches.

**v6** — amendment-alignment pass for #350, with no pre-registered rule changed.
10. §2 — the executor matrix is closed: the `[OPEN: #350]` marker is removed and
    the section now cites the accepted ADR 0012 amendment (Guile and Chibi
    first-class behind one seam; bounded retrieval removed from the required
    set). Arm E is recorded as unavailable by decision rather than by omission.
    The pre-registered rules in §0, §4, §5, §6, §7, §8 and §9 are untouched, so
    the ordering that gives them their value is preserved. *(coordinator)*

**v7** — owner sample-size decision on 2026-09-25, before any live run.
11. §1, §0 G2, §8 — the owner accepted a light sample over full rigor.
    Repetitions default to 1 (at most 3) and the matrix may run a named subset
    of the questions. G2 becomes a completion share of the questions actually
    run. One repetition gives no run-to-run noise band, so §6 step 2 can
    separate the executors only on a difference larger than the owner accepts
    as meaningful. The result is a weaker claim, and the artifact must say so.
    Provider cost may be unpriced (a flat-rate subscription); tokens are still
    recorded. §5 and G3 — answer quality is one blind 0–10 LLM-evaluator score
    per completed run, replacing the rubric dimensions and κ. *(owner)*
