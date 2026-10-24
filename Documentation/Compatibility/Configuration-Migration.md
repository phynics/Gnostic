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
replaces the source manifest. It syncs the backup file and containing directory
before replacement, then syncs the directory again after replacement. The
backup and replacement preserve the source owner, group, and mode. If the
invoking user cannot preserve ownership, migration fails before replacing the
source. A failure syncing the directory after rename reports that the migrated
file is already visible and keeps the backup for recovery. If validation or
backup creation fails, the source is not changed. The report includes the
backup path. Keep that backup until the migrated node has started successfully
and its Timelines and Workspaces are visible.

Migration validates and converts configuration values; it does not prove that
the configured Runtime executable exists or that its working directory is
accessible on the machine where the Node will run. On the target Node, validate
the migrated manifest before startup:

```sh
gnostic config validate --config ~/.gnostic/config.json
```

This checks the manifest against the running version's configuration rules.
Successful validation still does not prove that the Runtime can start; confirm
startup readiness on that Node before relying on the migrated configuration.

## Roll back

Stop Gnostic before restoring the manifest. Copy the backup path from the
migration report, then replace the migrated manifest with those exact bytes:

```sh
cp '/path/to/config.json.pre-v0.5-<timestamp>.bak' ~/.gnostic/config.json
```

Replace the example backup path with the exact path printed by the migration
command before running it.

Start Gnostic 0.4.2 to return to the prior configuration. Do not remove or
rewrite old execution-state files as part of rollback. If v0.5 has already
written new Timeline state, keep that state separate; 0.4.2 cannot read it.

For a failed or interrupted migration, leave the backup in place, restore it
before starting the old release, and retain both the backup and migrated file
for diagnosis. The command does not automatically restore execution history.
