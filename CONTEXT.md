# Gnostic domain constitution

This document is the canonical vocabulary for Gnostic. The relationships below
are Gnostic-owned unless a definition explicitly assigns ownership to a
backend.

## Node

A Node is one Gnostic host. It publishes one `protocolMajor` and may operate
several Ascendants.

## Ascendant

An Ascendant is a stable Gnostic logical agent identity. At startup an
Ascendant binds to one Ascendant Backend. Its UUID is Gnostic identity and may
survive a backend change made while the Node is stopped.

## Ascendant Backend

An Ascendant Backend owns execution for one Ascendant: model and tool
semantics, backend configuration, transcript/context state, persistence,
compaction, caches, checkpoints, and backend-native lifecycle. Gnostic owns the
host boundary and identity projection around it.

## Positronic Backend

A Positronic Backend is the Ascendant Backend implemented with PositronicKit.
PositronicKit `AgentInstance` and `Thread` are backend-private implementation
details; they are not Gnostic identity or public Gnostic protocol concepts.

## Timeline

A Timeline is Gnostic-owned identity and relationship state addressed by
Gnostic operations. Timeline identity is not backend transcript, model context,
execution, persistence, compaction, cache, or checkpoint state. A backend may
project a Timeline into its private state, but that projection cannot redefine
or erase Gnostic Timeline identity.

## Workspace

A Workspace is a discoverable capability resource. It is not inherently a
filesystem. A Workspace may expose filesystem tools, but its identity,
advertisement, attachment relationship, and capabilities are not determined
by a filesystem implementation.

## Attachment intent

Attachment intent is the Node's durable statement that a Gnostic Timeline is
attached to a Workspace. Gnostic owns this intent and does not silently erase
it when a backend or resource is unavailable.

## Effective status

Effective status describes whether an intended Workspace attachment can be
used now. The only values are `available`, `unavailable`, and `unsupported`.
Effective status is derived runtime state, separate from attachment intent.

## Turn

A Turn is a Timeline-addressed, admitted Gnostic operation. Its network and
host envelope are Gnostic-owned; model and tool execution semantics are owned
by the Ascendant Backend.

## Capability

A capability is a named, versioned behavior that a Node or Ascendant instance
can consume or advertise. Interoperability capabilities are selected by
`protocolMajor` and capability name, never by backend-kind assumptions.

## protocol major

`protocolMajor` identifies the incompatible Gnostic network contract carried by
an advertisement, request, result, stream, or replay update. A Node publishes
one major, and every direct operation revalidates compatibility.

## Atlas

Atlas is the optional, Positronic-specific continuity and context architecture
that supersedes Narrative. Atlas remains outside `GnosticCore`; generic Gnostic
identity and routing do not depend on it.

## Bounded legacy Agent terminology

`Agent` is retained only when naming an external protocol boundary, an
upstream/backend-native type, or historical data that has not yet been
migrated. New Gnostic-owned identity, lifecycle, and wire terminology uses
Ascendant. PositronicKit's `AgentInstance` remains backend-private and is not a
counterexample to this rule.
