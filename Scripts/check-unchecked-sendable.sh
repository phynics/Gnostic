#!/bin/sh
# Enforce the @unchecked Sendable audit from issue #268.
#
# Every `@unchecked Sendable` in Sources must carry a same-line
# `// SAFETY: <reason>` justification so a new conformance cannot be added
# without stating why checked Sendable is impossible or undesirable.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
offenders=$(grep -rn '@unchecked Sendable' "$root/Sources" --include='*.swift' \
    | grep -v '// SAFETY:' || true)

if [ -n "$offenders" ]; then
    echo "Unannotated @unchecked Sendable; add a '// SAFETY: <reason>' comment:" >&2
    printf '%s\n' "$offenders" >&2
    exit 1
fi

echo "unchecked-Sendable lint passed"
