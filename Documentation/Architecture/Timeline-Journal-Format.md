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
| `timestamp` | The event timestamp, as a JSON number of seconds since 2001-01-01T00:00:00Z. |
| `causalSpanID` | The causal span. The field is absent for an event without a span. |
| `payload` | A Gnostic event or an ACP v2 session update. |

JSON UUID values, such as `timelineID` and `replayEpoch`, use the uppercase
form that Foundation encodes. The committed fixture
`Tests/Fixtures/TimelineJournal/timeline-v1.golden.jsonl` pins the frame, the
checksum, and the JSON shape of every payload kind. Its tests check the frame
against a checksum that is computed without the implementation.

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
`clientTurnID`.

The admission digest is the lowercase hexadecimal SHA-256 of the RFC 8785
canonical form of the document
`{"acpVersionTag": <tag>, "prompt": <content blocks>}`. The version tag is
`ACPv2Protocol.versionTag`. The Turn sequence is one more than the highest
sequence the Timeline has admitted, so it increases in admission order. A reader
recomputes the digest from the stored prompt and tag, and it quarantines the
Timeline when they disagree. A Turn completion stores the Turn's outcome:
`completed`, `endedUnspecified`, `cancelled`, `failed`, `insertionUnknown`, or
`unavailable`. An ACP update stores the received `session/update` frame as a
JSON string in its `update` field. The string is the exact text of the line the
Runtime wrote, without its newline. Gnostic does not decode and encode it
again, so the string keeps `_meta`, unknown update kinds, fields that Gnostic's
typed form of a known kind does not model, number text such as `1.0` or
`18446744073709551617`, duplicate keys, key order, and spacing. It also keeps any
nesting depth, because a string has none.

The transport journals every `session/update` notification that has a
`sessionId` string that is not empty. That includes a frame whose `update` is
not an object, has no `sessionUpdate`, or does not fit the fixed type of its
kind. Gnostic's own consumers skip such an update, and the Turn does not fail.
The journal's `sessionID` field repeats the frame's `sessionId`. A reader gets
the typed form by decoding `params.update` of the stored text. It must not
treat the typed form as the record of the update.

Two kinds of line are not updates and are not journaled. A `session/update`
notification with no usable `sessionId` cannot belong to a Timeline. The
transport logs a warning, which names no Runtime content, and carries on. A line
that is not valid JSON-RPC is not a message. The transport drops it without a
log entry, as it always has. A JSON-RPC message that is nested too deeply to
decode is such a line too.

A reader also accepts the earlier shape of the `update` field, a JSON object
that holds the update. It reads that object as a typed update with no frame.
The committed fixture `timeline-v1.golden.jsonl` has both ACP payloads in this
shape.

A frame is part of its record, so the record is as large as the frame plus its
JSON escapes. The journal sets no limit on the size of a record. The transport
sets none on the size of a line, so a large frame is journaled whole. A frame
of N bytes takes more than N bytes of journal, up to six times N when it is
mostly control characters.

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
admission again. A completion with the outcome `insertionUnknown` is the same
state, recorded when the Runtime's response to the prompt was lost.

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

## Format version 1 before release

Format version 1 is not yet released. Gnostic changed the Turn admission digest
from FNV-1a over the message to the SHA-256 form above, and it replaced the
`legacy-text-v1` version tag with the ACP version tag, without a version bump.
The frame and the payload fields did not change. A journal that an earlier
development build wrote fails the digest check when Gnostic opens it, so the
Timeline is quarantined and nothing is rewritten. Discard such a journal.
After the first release, a digest change needs a new format version and a
migration.

Before release, Gnostic also changed what an ACP update record holds. It
stored the update as a JSON object that it rebuilt from a typed value, which
dropped fields and dropped a known kind that did not fit its type. Then it
stored a decoded JSON value, which changed number text and could not be encoded
again at great depth. It now stores the text of the received frame. The record
layout and the format version did not change. A journal that an earlier
development build wrote still opens and replays in its stored shape.

## Schema changes

Readers support only the format versions they name. Do not reinterpret an
unknown version or silently rewrite the source file. A migration must read the
old journal, write a separate new-version journal, and validate the new journal
before replacing or retiring the source. Keep the source until validation
passes.
