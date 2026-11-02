#!/bin/sh
# Checks the T4 acceptance helpers without a container, a broker or a build:
#   - container-shell.sh waits for the build directory lock before it invokes the runtime,
#   - journal.mjs reports an odd preserved frame and goes on.
# Needs sh, flock and node. Run it from anywhere:
#   Tests/Fixtures/T4Acceptance/selftest.sh
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
root_dir=$(CDPATH= cd -- "$here/../../.." && pwd -P)
work=$(mktemp -d)
failures=0
holder=
cleanup() {
	[ -z "$holder" ] || kill "$holder" 2> /dev/null
	rm -rf "$work"
}
trap cleanup EXIT

check() { # check <description> <command...>
	description=$1; shift
	if "$@"; then echo "ok   $description"; else echo "FAIL $description"; failures=$((failures + 1)); fi
}

# --- container-shell.sh and the build directory lock -------------------------------------
# A fake runtime records every call. The build directory is private to this check.
cat > "$work/fake-runtime" <<'FAKE'
#!/bin/sh
echo "$*" >> "$FAKE_RUNTIME_LOG"
exit 0
FAKE
chmod +x "$work/fake-runtime"
export FAKE_RUNTIME_LOG="$work/runtime.log"
export BUILD_DIR="$work/build"
export CONTAINER_RUNTIME="$work/fake-runtime"
export SPM_CACHE_DIR="$work/spm"
mkdir -p "$BUILD_DIR"

"$root_dir/.devcontainer/lock.sh" "$BUILD_DIR" 30 sleep 20 2> /dev/null &
holder=$!
sleep 1

: > "$FAKE_RUNTIME_LOG"
BUILD_LOCK_TIMEOUT=2 "$here/container-shell.sh" true > "$work/locked.out" 2>&1
status=$?
check "a command exits 75 when the lock stays held" test "$status" = 75
check "a command does not invoke the runtime while the lock is held" test ! -s "$FAKE_RUNTIME_LOG"
check "the timeout message names the build directory" grep -q "waiting for build resource" "$work/locked.out"

kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null; holder=
: > "$FAKE_RUNTIME_LOG"
BUILD_LOCK_TIMEOUT=2 "$here/container-shell.sh" true > /dev/null 2>&1
check "a command runs once the lock is free" grep -q "^run .*true" "$FAKE_RUNTIME_LOG"
check "a command mounts the build directory writable" grep -q "$BUILD_DIR:/workspace/.build " "$FAKE_RUNTIME_LOG"

# A shell takes no lock, so it starts while the lock is held, and its build directory is read-only.
"$root_dir/.devcontainer/lock.sh" "$BUILD_DIR" 30 sleep 20 2> /dev/null &
holder=$!
sleep 1
: > "$FAKE_RUNTIME_LOG"
BUILD_LOCK_TIMEOUT=2 "$here/container-shell.sh" < /dev/null > /dev/null 2>&1
check "a shell starts while the lock is held" grep -q "^run .* bash" "$FAKE_RUNTIME_LOG"
check "a shell mounts the build directory read-only" grep -q "$BUILD_DIR:/workspace/.build:ro" "$FAKE_RUNTIME_LOG"
kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null; holder=
unset BUILD_DIR CONTAINER_RUNTIME SPM_CACHE_DIR

# --- journal.mjs with odd preserved frames ------------------------------------------------
node -e '
	const fs = require("fs");
	const bom = "﻿";
	const frame = (update) => JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { sessionId: "s", update } });
	const record = (sequence, payload, prefix = "") => `${prefix}0000000000000000 1 ` + JSON.stringify({ formatVersion: 1, sequence, payload });
	const acp = (text) => ({ acpUpdate: { sessionID: "s", update: { update: text } } });
	const lines = [
		record(1, { replayEpochStarted: { afterSequence: 0 } }, bom),
		record(2, acp(frame({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "héllo" } }))),
		record(3, acp(bom + frame({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "bom" } }))),
		record(4, acp(frame({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: 42 } }))),
		record(5, acp("not json {")),
		record(6, acp(frame({ sessionUpdate: "agent_message_chunk", content: [{ type: "text", text: "ab" }, { type: "text" }] }))),
		"this line is not a journal record",
		record(8, { turnCompleted: { outcome: "completed" } }),
	];
	fs.writeFileSync(process.argv[1], lines.join("\n") + "\n");' "$work/journal.jsonl"

node "$here/journal.mjs" summary "$work/journal.jsonl" > "$work/summary.out" 2>&1
check "summary exits 0 with odd frames" test "$?" = 0
check "summary reads a leading byte order mark on a line" grep -q "1 seq=1 replayEpochStarted" "$work/summary.out"
check "summary reads a byte order mark in the frame text" grep -q "3 seq=3 acpUpdate agent_message_chunk" "$work/summary.out"
check "summary reports frame text that is not JSON" grep -q "5 seq=5 acpUpdate (unsupported: frame text is not JSON" "$work/summary.out"
check "summary reports an unreadable record and goes on" sh -c "grep -q 'unreadable record' '$work/summary.out' && grep -q '8 seq=8 turnCompleted completed' '$work/summary.out'"

node "$here/journal.mjs" text "$work/journal.jsonl" > "$work/text.out" 2>&1
check "text exits 0 with odd frames" test "$?" = 0
check "text counts the bytes of valid chunks only" grep -q "journal: agent text 9 bytes in 2 chunks" "$work/text.out"
check "text reports numeric text and does not count it" grep -q "seq=4 unsupported agent_message_chunk, not counted" "$work/text.out"
check "text reports a block without text" grep -q "seq=6 unsupported agent_message_chunk, not counted" "$work/text.out"
check "text reports frame text that is not JSON" grep -q "seq=5 unsupported frame, not counted" "$work/text.out"

if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
