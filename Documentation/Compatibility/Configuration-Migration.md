# Operator configuration migration

`gnostic config migrate` converts the immediate pre-v0.5 schema-v2 manifest
from Gnostic 0.4.2. It changes the manifest's top-level `ascendants` array to
`runtimeInstances` and Timeline references from `operatingAscendantID` to
`runtimeInstanceID`. Node, Runtime instance, Timeline, and Workspace UUIDs,
resource metadata, Timeline flags, Workspaces, broker settings, and supported
ACP launch settings are preserved.

The command maps an `acp-client` configuration only when it has a non-empty
`command` and no settings the migration cannot represent. It rejects
`positronic`, `letta`, and other backend kinds with a remediation message. It
does not migrate schema v1 or convert old Turns, Sessions, Timeline databases,
or experiment traces. Those state files are left in place and are not used by
v0.5.

## Preview and apply

First preview the structured diff. The source file remains unchanged and no
backup is created:

```sh
gnostic config migrate --dry-run --format json --config ~/.gnostic/config.json
```

Review the reported changes and preserved IDs, then apply:

```sh
gnostic config migrate --format json --config ~/.gnostic/config.json
```

Apply mode creates an exact, timestamped sibling backup before it atomically
replaces the source manifest. If validation or backup creation fails, the
source is not changed. The report includes the backup path. Keep that backup
until the migrated node has started successfully and its Timelines and
Workspaces are visible.

## Roll back

Stop Gnostic before restoring the manifest. Copy the backup path from the
migration report, then replace the migrated manifest with those exact bytes:

```sh
cp -- '/path/to/config.json.pre-v0.5-<timestamp>.bak' ~/.gnostic/config.json
```

Replace the example backup path with the exact path printed by the migration
command before running it.

Start Gnostic 0.4.2 to return to the prior configuration. Do not remove or
rewrite old execution-state files as part of rollback. If v0.5 has already
written new Timeline state, keep that state separate; 0.4.2 cannot read it.

For a failed or interrupted migration, leave the backup in place, restore it
before starting the old release, and retain both the backup and migrated file
for diagnosis. The command does not automatically restore execution history.
