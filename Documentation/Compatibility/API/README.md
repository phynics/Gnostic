# Public API baseline

This directory holds the public API of the two stable products,
`GnosticProtocol` and `GnosticClient`, as the Swift compiler prints it. `make
verify` fails when the current build differs from these files (issue #676).

| File | Product |
| --- | --- |
| `GnosticProtocol.swiftinterface` | `GnosticProtocol` |
| `GnosticClient.swiftinterface` | `GnosticClient` |

The files are generated. Do not edit them by hand.

## Check the API

```sh
make api-check
```

The target builds both modules in the pinned development container, takes the
compiler's `.swiftinterface` output, and compares it with the baseline. A
difference fails the target. It prints a unified diff (`-` is the baseline, `+`
is the current build) and the command to regenerate the baseline. `make verify`
runs it before the test suite. It does not need `gnostic-pk-runtime`.

The first run in a build directory compiles the package dependencies a second
time, in `.build/api-interface`, because the interface flag changes every
module's compile settings. A cold run takes several minutes. Later runs only
recompile the changed modules.

## Update the baseline

Change the baseline only for a deliberate public API change:

```sh
make api-update
git diff Documentation/Compatibility/API/
```

Commit the regenerated files with the source change. **A baseline change makes
the pull request review-required** under "Review and finish" in `AGENTS.md`,
because it changes a public contract. Record the API diff and the reviewer's
findings in the owning issue. Do not split the API change from the code that
causes it to avoid review.

## What the baseline covers

The `.swiftinterface` text lists every public declaration the compiler exports
from the module. That includes the cases that a scan of source text misses:

- a `public typealias` that spans several lines;
- a member of a `public extension`, or of an extension that adds a conformance;
- `@_exported import`;
- default argument values, attributes, and generic constraints;
- every type a public signature names, qualified by its module. A `GnosticCore`
  type in a `GnosticClient` signature prints as `GnosticCore::Name`, and a name
  that contains "Ascendant" is a plain text match.

`StableSurfaceFitnessTests` reads these files for the stable-surface rules (no
Ascendant name, no `GnosticCore` type in a public signature, no ACP typealias in
`GnosticProtocol`). The test runs on every platform, because it reads the
committed text. `make api-check` keeps that text equal to the compiler output.

It does not cover:

- SPI (`@_spi`) and `package` declarations. The baseline holds the public
  interface only.
- Anything below public: internal, private, and the private stored properties
  of public types. The compiler prints those stored properties because they
  affect layout. The script drops them and fails if other private text remains.
- Binary compatibility. The package is distributed as source.
- The preview product `GnosticACPWire`, and every other product. A stable
  signature that names a `GnosticACPWire` type is recorded as written.
- Behavior and wire payloads. Their tests cover those.

## Platform limit

The baseline is the Linux output of the pinned container (Swift 6.4). The text
names Foundation types by their Linux module, for example
`FoundationEssentials::UUID`; on macOS the same type prints as
`Foundation::UUID`. So `make api-check` runs on Linux only, in the container,
in the `verify` workflow job. The macOS jobs do not run it. They still run
`StableSurfaceFitnessTests` against the committed text. A toolchain upgrade in
the container image can change the printed text; regenerate the baseline in the
same pull request and read the diff.

## Tools compared

The container ships `swift-api-digester` and `swift package
diagnose-api-breaking-changes`. The check uses `.swiftinterface` text.

| Option | Result in the pinned container | Decision |
| --- | --- | --- |
| `swift-api-digester -dump-sdk` on the built modules | Fails with `missing required module '_AtomicsShims'` until the caller passes the module map of every C dependency. With those flags it writes a JSON tree of about 36000 lines for `GnosticProtocol`. It has no marker for `@_exported import`, and it needs a custom renderer for a readable diff. | Rejected. |
| `swift package diagnose-api-breaking-changes <ref>` | Works from a standalone clone of the repository. It compares the working tree with a git ref, reports breaking changes only, and takes 10 to 20 minutes on a cold cache. It cannot run in a git worktree, because the worktree's git directory is outside the container mount. It cannot compare against a committed file. | Used for patch releases (below), not for the gate. |
| `-Xswiftc -emit-module-interface` | Works with `--scratch-path`. The text is the compiler's own, deterministic across runs, and readable as a diff. It reports additions as well as removals. `-enable-library-evolution` does not build (`swift-crypto`), so the compiler prints a warning that this script suppresses and the interface lists private stored properties that the script filters. | Chosen. |

Determinism: two runs on the same source, and one run after deleting the
scratch directory, wrote byte-identical files. The script removes the
`// swift-*` header (compiler build and package name) and fails when the text
contains `/workspace`, `/tmp`, `/home`, `/root`, or `/Users`.

## Patch releases: compare with the rc tag

The baseline gates a pull request. For a 0.5.x patch, also check that the patch
breaks nothing against the rc tag. `swift package diagnose-api-breaking-changes`
works in the pinned container from a standalone clone:

```sh
git clone https://github.com/phynics/Gnostic.git /tmp/gnostic-patch-check
cd /tmp/gnostic-patch-check
git checkout <patch-branch>
CONTAINER_RUNTIME=podman ./.devcontainer/run.sh bash -o pipefail -c \
  'git config --global --add safe.directory /workspace
   swift package --cache-path /workspace/.swiftpm-cache diagnose-api-breaking-changes 0.5.0-rc.1 \
     --products GnosticProtocol --products GnosticClient'
```

Replace `0.5.0-rc.1` with the rc tag that the patch follows. The command exits
non-zero when it finds a breaking change, and it lists each one. It reports
removals and changes only, so the baseline remains the check for additions.
Its output contains absolute paths from the clone. Do not commit them.
