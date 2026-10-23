# Timeline journal format

This page defines the on-disk format used by `TimelineJournal` in Gnostic v0.5.
ADR 0021 §5 defines the journal's role and recovery guarantees.

## File location

`gnostic serve` requires `GNOSTIC_STATE_HOME` or `--turn-log`. An explicit
`--turn-log` path uses its parent as the state home. `gnostic-runner` requires
`GNOSTIC_STATE_HOME` or `--state-home`. Gnostic stores each Node's journals under:

```text
<state-home>/timeline-journals/<node-id>/timeline-<timeline-id>-v1.jsonl
```

The Node ID and Timeline ID use lowercase UUID strings. The journal directory
uses mode `0700`. Each journal file uses mode `0600`.

## Record framing

Each record is one UTF-8 JSON value followed by a newline. The frame is:

```text
<checksum-hex> <unix-milliseconds> <record-json>\n
```

The checksum is a 64-bit FNV-1a value over the timestamp and JSON bytes. Gnostic
syncs each complete frame before `append` returns. The checksum detects
accidental damage. It does not provide tamper protection.

Each JSON record has these fields:

| Field | Meaning |
| --- | --- |
| `formatVersion` | Storage schema version. The current value is `1`. |
| `timelineID` | The Timeline that owns this event. |
| `replayEpoch` | The writer epoch for this event. |
| `sequence` | A contiguous, per-Timeline sequence number starting at `1`. |
| `timestamp` | The event timestamp. |
| `causalSpanID` | The causal span, or `null` for an event without a span. |
| `payload` | A Gnostic event or an ACP v2 session update. |

The first event starts the initial replay epoch. Every later open appends an
epoch-start event that names the previous epoch and sequence. Normal events
follow that epoch marker. The journal store serializes all writers for one
Timeline in a Node.

## Event payloads

The payload records Timeline creation and rename, Workspace attachment changes,
Session transitions, Project changes, Turn admission and completion, permission
decisions, and ACP updates. A Session transition stores the session ID, Runtime instance ID,
state, Project kind, and exact `cwd`. A Turn admission stores its canonical
prompt digest, ACP version tag, content blocks, Turn sequence, and
`clientTurnID`. An ACP update stores the `ACPSessionUpdate` value as received.
That value keeps `_meta` and unknown update kinds.

A `projectChanged` event stores the desired `Project` and retires the latest
Session projection before the old Session is closed. Recovery uses this desired
placement when no explicit Project is configured. An explicit manifest Project
takes precedence, so changing its directory starts a new Session on the same
Timeline.

The shared permission coordinator syncs decisions before publishing
selection or releasing approval. ACP replies and Workspace gateway dispatch
check the same idempotent decision record. A failed journal write cancels the
permission request and prevents Workspace tool invocation.

Session updates received while a new Session binding is being committed are
queued, then synced and forwarded in receipt order after the Session transition.
An idle update alone does not confirm prompt insertion. Without a committed
completion, recovery retains `insertionUnknown` and never dispatches that
admission again.

The Turn event log remains a separate digest-only ledger. It does not replace
the Timeline journal or contain conversation content.

## Recovery and replay

The newline commits a record. If the final frame has no newline, recovery
truncates that uncommitted tail to the previous valid frame. A newline-terminated
frame with an invalid checksum or record quarantines the Timeline. Gnostic keeps
the file unchanged, reports the valid sequence and reason, and rejects later
writes. A reader rejects an unknown `formatVersion`. Committed records are
validated before any torn suffix is truncated, so an unsupported or quarantined
journal remains byte-for-byte unchanged.

`replay(after:)` accepts a cursor only when its sequence and replay epoch match
one committed record. It rejects a cursor from a different epoch. Sequence
numbers do not restart when a new epoch begins.

## Schema changes

Readers support only the format versions they name. Do not reinterpret an
unknown version or silently rewrite the source file. A migration must read the
old journal, write a separate new-version journal, and validate the new journal
before replacing or retiring the source. Keep the source until validation
passes.
