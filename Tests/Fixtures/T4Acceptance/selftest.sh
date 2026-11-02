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

# --- t4_node_start refuses to start a second Node ---------------------------------------
# A stub `gnostic` prints the readiness line and stays up. The recorded process is a live
# process whose command is named gnostic.
(
	export T4_WORK="$work/t4" T4_BIN="$work/t4bin" T4_BROKER_HOST=127.0.0.1 T4_BROKER_PORT=1 T4_NAMESPACE=selftest T4_WORKSPACE_ID=none
	mkdir -p "$T4_WORK/pids" "$T4_BIN"
	cat > "$T4_BIN/gnostic" <<'STUB'
#!/bin/sh
echo started >> "$T4_WORK/stub-starts"
echo "advertised objects"
exec sleep 30
STUB
	chmod +x "$T4_BIN/gnostic"
	printf '#!/bin/sh\nsleep 30\n' > "$work/gnostic-live"
	chmod +x "$work/gnostic-live"
	"$work/gnostic-live" &
	live=$!
	echo "$live" > "$T4_WORK/pids/a"
	. "$here/t4.sh"
	t4_node_start a "$work/manifest.json" "$T4_WORK/state-a" > "$work/refuse.out" 2>&1
	refused=$?
	kill "$live" 2> /dev/null
	[ "$refused" = 1 ] && grep -q "node a is already running (pid $live)" "$work/refuse.out" \
		&& [ "$(cat "$T4_WORK/pids/a")" = "$live" ] && [ ! -e "$T4_WORK/stub-starts" ]
) && started_refusal=0 || started_refusal=1
check "t4_node_start refuses while its recorded process is alive, keeps the PID, and starts nothing" test "$started_refusal" = 0

(
	export T4_WORK="$work/t4b" T4_BIN="$work/t4bin" T4_BROKER_HOST=127.0.0.1 T4_BROKER_PORT=1 T4_NAMESPACE=selftest T4_WORKSPACE_ID=none
	mkdir -p "$T4_WORK/pids"
	echo 999999 > "$T4_WORK/pids/a"
	. "$here/t4.sh"
	t4_node_start a "$work/manifest.json" "$T4_WORK/state-a" > "$work/stale.out" 2>&1 \
		&& [ -e "$T4_WORK/stub-starts" ] || exit 1
	kill "$(cat "$T4_WORK/pids/a")" 2> /dev/null
) && stale_start=0 || stale_start=1
check "t4_node_start starts when the recorded process is gone" test "$stale_start" = 0

# --- t4_kill_during_call and t4_wait_prompts are bounded and never strand a frozen Node ----
(
	export T4_WORK="$work/t4c" T4_BIN="$work/t4bin" T4_BROKER_HOST=127.0.0.1 T4_BROKER_PORT=1 T4_NAMESPACE=selftest T4_WORKSPACE_ID=none T4_WAIT_SECONDS=2
	mkdir -p "$T4_WORK/pids" "$T4_WORK/fixture"
	. "$here/t4.sh"
	state() { ps -o stat= -p "$1" 2> /dev/null | cut -c1; }
	node_up() { sleep 60 & echo $! > "$T4_WORK/pids/b"; NODE=$!; }
	fail=0

	node_up; printf 'session/prompt 1: x\nsession/prompt 1: FAILED code=1\n' > "$T4_WORK/log"
	t4_kill_during_call "$T4_WORK/log" b 0 > /dev/null 2>&1; rc=$?
	[ "$rc" = 1 ] && [ "$(state "$NODE")" != T ] && [ -n "$(state "$NODE")" ] || { echo "client failed first: rc=$rc"; fail=1; }
	kill "$NODE" 2> /dev/null

	node_up; : > "$T4_WORK/log"
	t4_kill_during_call "$T4_WORK/log" b 0 > /dev/null 2>&1; rc=$?
	[ "$rc" = 1 ] && [ -n "$(state "$NODE")" ] && [ "$(state "$NODE")" != T ] || { echo "no request: rc=$rc"; fail=1; }
	kill "$NODE" 2> /dev/null

	node_up; echo 'permission request 1: "x"' > "$T4_WORK/log"
	t4_kill_during_call "$T4_WORK/log" b 0 > /dev/null 2>&1; rc=$?
	sleep 0.3
	[ "$rc" = 1 ] && [ -n "$(state "$NODE")" ] && [ "$(state "$NODE")" != T ] || { echo "never answered: rc=$rc state=$(state "$NODE")"; fail=1; }
	kill "$NODE" 2> /dev/null

	node_up; echo 'permission request 1: "x"' > "$T4_WORK/log"
	( sleep 1; echo 'permission request 1: answered allow_once' >> "$T4_WORK/log" ) &
	t4_kill_during_call "$T4_WORK/log" b 0 > /dev/null 2>&1; rc=$?
	sleep 0.3
	[ "$rc" = 0 ] && [ -z "$(state "$NODE")" ] || { echo "answered: rc=$rc state=$(state "$NODE")"; fail=1; }
	kill "$NODE" 2> /dev/null

	: > "$T4_WORK/fixture/prompts.log"
	t4_wait_prompts 0 1 > /dev/null 2>&1 && { echo "wait_prompts succeeded with no prompt"; fail=1; }
	echo prompt > "$T4_WORK/fixture/prompts.log"
	t4_wait_prompts 0 1 > /dev/null 2>&1 || { echo "wait_prompts failed with a prompt"; fail=1; }
	exit $fail
) > "$work/bounded.out" 2>&1 && bounded=0 || bounded=1
check "t4_kill_during_call and t4_wait_prompts stop at their bound and leave no Node frozen" test "$bounded" = 0
[ "$bounded" = 0 ] || cat "$work/bounded.out"

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
