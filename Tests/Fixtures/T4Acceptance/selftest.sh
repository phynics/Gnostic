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

# --- the t4.sh process helpers ---------------------------------------------------------------
# T4_SELFTEST_T4 names the t4.sh under test. The default is the one beside this script.
t4sh=${T4_SELFTEST_T4:-$here/t4.sh}

# A stand-in for a Node: a script named gnostic that sleeps. Its record is made by the helper
# under test, from `ps`, exactly as t4_node_start makes it.
printf '#!/bin/sh\nsleep 60\n' > "$work/gnostic-live"
chmod +x "$work/gnostic-live"
# A process that is not ours but whose command line mentions gnostic, like the Python
# process in the review that held /tmp/gnostic-notes.txt.
printf '#!/bin/sh\nsleep 60\n' > "$work/unrelated"
chmod +x "$work/unrelated"
mkdir -p "$work/t4bin"
cat > "$work/t4bin/gnostic" <<'STUB'
#!/bin/sh
echo started >> "$T4_WORK/stub-starts"
echo "advertised objects"
exec sleep 60
STUB
chmod +x "$work/t4bin/gnostic"
state() { ps -o stat= -p "$1" 2> /dev/null | cut -c1; }

# t4env <dir>: a private work directory and the variables t4.sh reads.
t4env() {
	export T4_WORK="$work/$1" T4_BIN="$work/t4bin" T4_BROKER_HOST=127.0.0.1 T4_BROKER_PORT=1 T4_NAMESPACE=selftest T4_WORKSPACE_ID=none T4_WAIT_SECONDS=2
	mkdir -p "$T4_WORK/pids" "$T4_WORK/fixture"
}

# A live Node whose record is valid.
(
	t4env refuse
	. "$t4sh"
	"$work/gnostic-live" &
	live=$!
	echo "$live" > "$T4_WORK/pids/a"; _t4_record a "$live"
	t4_node_start a "$work/manifest.json" "$T4_WORK/state-a" > "$work/refuse.out" 2>&1
	refused=$?
	kill "$live" 2> /dev/null
	[ "$refused" = 1 ] && grep -q "node a is already running (pid $live)" "$work/refuse.out" \
		&& [ "$(cat "$T4_WORK/pids/a")" = "$live" ] && [ ! -e "$T4_WORK/stub-starts" ]
) && ok=0 || ok=1
check "t4_node_start refuses while its recorded process is alive, keeps the PID, and starts nothing" test "$ok" = 0

(
	t4env stale
	. "$t4sh"
	echo 999999 > "$T4_WORK/pids/a"
	t4_node_start a "$work/manifest.json" "$T4_WORK/state-a" > "$work/stale.out" 2>&1 && [ -e "$T4_WORK/stub-starts" ] || exit 1
	_t4_owned a || exit 1
	kill "$_t4_pid" 2> /dev/null
) && ok=0 || ok=1
check "t4_node_start starts when the recorded process is gone, and records its identity" test "$ok" = 0

# PID reuse: the record names a PID that now belongs to another process. Three variants: the
# identity file is that of the old process, the identity file is missing, and the PID is alive
# but its command line differs.
(
	fail=0
	for variant in reused noid; do
		t4env "reuse-$variant"
		. "$t4sh"
		"$work/gnostic-live" & old=$!
		_t4_record a "$old"
		kill "$old"; wait "$old" 2> /dev/null
		"$work/unrelated" /tmp/gnostic-notes.txt & other=$!
		echo "$other" > "$T4_WORK/pids/a"
		[ "$variant" = noid ] && rm -f "$T4_WORK/pids/a.id"

		t4_node_stop a > "$work/reuse.out" 2>&1
		{ [ -n "$(state "$other")" ] && [ "$(state "$other")" != T ] && grep -q "not the process that was started" "$work/reuse.out" && [ ! -e "$T4_WORK/pids/a" ]; } || { echo "$variant: t4_node_stop signalled or kept the record"; fail=1; }

		echo "$other" > "$T4_WORK/pids/a"
		t4_node_kill a > "$work/reuse.out" 2>&1
		{ [ -n "$(state "$other")" ] && [ "$(state "$other")" != T ]; } || { echo "$variant: t4_node_kill signalled the other process"; fail=1; }

		echo "$other" > "$T4_WORK/pids/a"
		t4_node_start a "$work/manifest.json" "$T4_WORK/state-a" > "$work/reuse.out" 2>&1
		{ [ -n "$(state "$other")" ] && [ "$(state "$other")" != T ] && ! grep -q "already running" "$work/reuse.out"; } || { echo "$variant: t4_node_start refused for another process"; fail=1; }
		[ -e "$T4_WORK/pids/a" ] && kill "$(cat "$T4_WORK/pids/a")" 2> /dev/null

		echo "$other" > "$T4_WORK/pids/b"; [ "$variant" = noid ] || { "$work/gnostic-live" & o2=$!; _t4_record b "$o2"; kill "$o2"; wait "$o2" 2> /dev/null; }
		echo 'permission request 1: "x"' > "$T4_WORK/log"
		t4_kill_during_call "$T4_WORK/log" b 0 > "$work/reuse.out" 2>&1; rc=$?
		sleep 0.3
		{ [ "$rc" = 1 ] && [ -n "$(state "$other")" ] && [ "$(state "$other")" != T ]; } || { echo "$variant: t4_kill_during_call froze or killed the other process (rc=$rc state=$(state "$other"))"; fail=1; }
		kill "$other" 2> /dev/null
	done
	exit $fail
) > "$work/reuse.report" 2>&1 && ok=0 || ok=1
check "a reused PID is never signalled, and the record is cleared and reported" test "$ok" = 0
[ "$ok" = 0 ] || cat "$work/reuse.report"

# A record stays valid in another terminal's time zone or locale.
(
	t4env zone
	. "$t4sh"
	sleep 60 & live=$!
	echo "$live" > "$T4_WORK/pids/b"
	TZ=UTC LC_ALL=C _t4_record b "$live"
	TZ=Asia/Tokyo _t4_owned b; first=$?
	TZ=America/New_York LC_ALL=POSIX _t4_owned b; second=$?
	kept=$(cat "$T4_WORK/pids/b" 2> /dev/null)
	kill "$live" 2> /dev/null
	[ "$first" = 0 ] && [ "$second" = 0 ] && [ "$kept" = "$live" ]
) && ok=0 || ok=1
check "a recorded process keeps its identity in another time zone or locale" test "$ok" = 0

# The broker guard.
(
	t4env broker
	mkdir -p "$work/fakebin"
	printf '#!/bin/sh\necho launched >> "$T4_WORK/broker-launches"\nexec sleep 60\n' > "$work/fakebin/mosquitto"
	printf '#!/bin/sh\nexit 0\n' > "$work/fakebin/mosquitto_pub"
	chmod +x "$work/fakebin/mosquitto" "$work/fakebin/mosquitto_pub"
	PATH="$work/fakebin:$PATH"
	. "$t4sh"
	printf '#!/bin/sh\nsleep 60\n' > "$work/mosquitto-live"; chmod +x "$work/mosquitto-live"
	"$work/mosquitto-live" & live=$!
	echo "$live" > "$T4_WORK/pids/broker"; _t4_record broker "$live"
	t4_broker_start > "$work/broker.out" 2>&1
	refused=$?
	kill "$live" 2> /dev/null
	[ "$refused" = 1 ] && grep -q "broker is already running (pid $live)" "$work/broker.out" \
		&& [ "$(cat "$T4_WORK/pids/broker")" = "$live" ] && [ ! -e "$T4_WORK/broker-launches" ] || exit 1
	rm -f "$T4_WORK/pids/broker" "$T4_WORK/pids/broker.id"
	t4_broker_start > "$work/broker.out" 2>&1 && [ -e "$T4_WORK/broker-launches" ] || exit 1
	t4_broker_stop > /dev/null 2>&1
) && ok=0 || ok=1
check "t4_broker_start refuses while the recorded broker is alive, and starts when it is gone" test "$ok" = 0

# t4_kill_during_call and t4_wait_prompts are bounded and never strand a frozen Node.
(
	t4env bounded
	. "$t4sh"
	node_up() { "$work/gnostic-live" & NODE=$!; echo "$NODE" > "$T4_WORK/pids/b"; _t4_record b "$NODE"; }
	fail=0

	node_up; printf 'session/prompt 1: x\nsession/prompt 1: FAILED code=1\n' > "$T4_WORK/log"
	t4_kill_during_call "$T4_WORK/log" b 0 > /dev/null 2>&1; rc=$?
	[ "$rc" = 1 ] && [ -n "$(state "$NODE")" ] && [ "$(state "$NODE")" != T ] || { echo "client failed first: rc=$rc"; fail=1; }
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
	exit $fail
) > "$work/bounded.out" 2>&1 && ok=0 || ok=1
check "t4_kill_during_call stops at its bound and leaves no Node frozen" test "$ok" = 0
[ "$ok" = 0 ] || cat "$work/bounded.out"

# An interrupt during the freeze kills the frozen Node. Node starts the shell with default
# signal handling, so the interrupt is not ignored the way a background job would ignore it.
cat > "$work/interrupt.js" <<'JS'
const { spawn, spawnSync } = require("child_process");
const [, , t4sh, nodePid] = process.argv;
const stat = () => spawnSync("ps", ["-o", "stat=", "-p", nodePid], { encoding: "utf8" }).stdout.trim()[0] ?? "";
const child = spawn("sh", ["-c", `. "${t4sh}"; t4_kill_during_call "$T4_WORK/log" b 0`], { stdio: "ignore" });
let frozen = false;
const deadline = Date.now() + 8000;
const poll = setInterval(() => {
  if (stat() === "T") { frozen = true; clearInterval(poll); child.kill("SIGINT"); }
  else if (Date.now() > deadline) { clearInterval(poll); child.kill("SIGKILL"); }
}, 50);
child.on("exit", () => setTimeout(() => {
  const after = stat();
  console.log(`frozen=${frozen} after=${after === "" ? "dead" : after}`);
  process.exit(frozen && after === "" ? 0 : 1);
}, 500));
JS
(
	t4env interrupt
	export T4_WAIT_SECONDS=20
	. "$t4sh"
	"$work/gnostic-live" & NODE=$!
	echo "$NODE" > "$T4_WORK/pids/b"; _t4_record b "$NODE"
	echo 'permission request 1: "x"' > "$T4_WORK/log"
	node "$work/interrupt.js" "$t4sh" "$NODE" > "$work/interrupt.out" 2>&1; rc=$?
	kill -CONT "$NODE" 2> /dev/null; kill "$NODE" 2> /dev/null
	exit $rc
) && ok=0 || ok=1
check "an interrupt during the freeze kills the frozen Node" test "$ok" = 0
[ "$ok" = 0 ] || cat "$work/interrupt.out"

# t4_wait_prompts fails closed.
(
	t4env prompts
	. "$t4sh"
	fail=0
	t4_wait_prompts 0 1 > "$work/wait.out" 2>&1; rc=$?
	[ "$rc" != 0 ] && grep -q "missing or unreadable" "$work/wait.out" && ! grep -qi "integer expression" "$work/wait.out" || { echo "missing log: rc=$rc"; cat "$work/wait.out"; fail=1; }
	t4_wait_prompts 0 1 2> /dev/null && t4_node_kill a > "$work/wait-kill.out" 2>&1
	[ ! -s "$work/wait-kill.out" ] || { echo "t4_node_kill ran after a failed wait"; fail=1; }
	: > "$T4_WORK/fixture/prompts.log"
	t4_wait_prompts 0 1 > /dev/null 2>&1 && { echo "empty log succeeded"; fail=1; }
	echo prompt > "$T4_WORK/fixture/prompts.log"
	t4_wait_prompts 0 1 > /dev/null 2>&1 || { echo "wait failed with a prompt"; fail=1; }
	exit $fail
) > "$work/waitreport.out" 2>&1 && ok=0 || ok=1
check "t4_wait_prompts fails after its bound when the log is missing, and succeeds on a prompt" test "$ok" = 0
[ "$ok" = 0 ] || cat "$work/waitreport.out"

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
