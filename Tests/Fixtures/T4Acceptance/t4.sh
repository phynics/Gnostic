# Shell helpers for the T4 acceptance runbook. Source this file; do not run it.
#
#   . Tests/Fixtures/T4Acceptance/t4.sh
#
# It works in bash and zsh and uses no bash-only syntax. It needs these
# variables, which `render.mjs --print-env` and the runbook set:
#   T4_WORK T4_NAMESPACE T4_NODE_A_ID T4_RUNTIME_ID T4_WORKSPACE_ID
#   T4_BROKER_HOST T4_BROKER_PORT
#   T4_BIN        the directory that holds the release gnostic binary
#   T4_FIXTURES   the Tests/Fixtures/T4Acceptance directory
# Every process runs in the background. Its log is $T4_WORK/logs/<name>.log and
# its process ID is in $T4_WORK/pids/<name>.

# _t4_running <name> <command word>: succeed when the process ID recorded for <name> is
# alive and is a <command word> process. A frozen process (SIGSTOP) counts as alive.
_t4_running() {
	[ -f "$T4_WORK/pids/$1" ] || return 1
	_alive_pid=$(cat "$T4_WORK/pids/$1")
	kill -0 "$_alive_pid" 2> /dev/null || return 1
	case $(ps -p "$_alive_pid" -o args= 2> /dev/null) in *"$2"*) return 0 ;; *) return 1 ;; esac
}

t4_broker_start() {
	if _t4_running broker mosquitto; then
		echo "broker is already running (pid $(cat "$T4_WORK/pids/broker")); run t4_broker_stop first" >&2
		return 1
	fi
	mkdir -p "$T4_WORK/logs" "$T4_WORK/pids"
	cat > "$T4_WORK/mosquitto.conf" <<EOF
per_listener_settings true
listener $T4_BROKER_PORT $T4_BROKER_HOST
allow_anonymous true
persistence false
log_dest stderr
EOF
	mosquitto -c "$T4_WORK/mosquitto.conf" > "$T4_WORK/logs/broker.log" 2>&1 &
	echo $! > "$T4_WORK/pids/broker"
	for _ in $(seq 1 50); do
		if mosquitto_pub -h "$T4_BROKER_HOST" -p "$T4_BROKER_PORT" -t t4/probe -m ready > /dev/null 2>&1; then
			echo "broker online at $T4_BROKER_HOST:$T4_BROKER_PORT (pid $(cat "$T4_WORK/pids/broker"))"
			return 0
		fi
		sleep 0.2
	done
	echo "broker did not come online; see $T4_WORK/logs/broker.log" >&2
	return 1
}

# t4_node_start <name> <manifest> <state-dir>
t4_node_start() {
	_name=$1 _manifest=$2 _state=$3
	# A second Node with the same configuration and identity would overwrite the recorded
	# process ID and leave the first Node running with no record.
	if _t4_running "$_name" gnostic; then
		echo "node $_name is already running (pid $(cat "$T4_WORK/pids/$_name")); run t4_node_stop $_name first" >&2
		return 1
	fi
	mkdir -p "$T4_WORK/logs" "$T4_WORK/pids" "$_state"
	GNOSTIC_STATE_HOME="$_state" "$T4_BIN/gnostic" serve --config "$_manifest" \
		--host "$T4_BROKER_HOST" --port "$T4_BROKER_PORT" --namespace "$T4_NAMESPACE" \
		> "$T4_WORK/logs/$_name.log" 2>&1 &
	echo $! > "$T4_WORK/pids/$_name"
	for _ in $(seq 1 100); do
		if grep -q "advertised objects" "$T4_WORK/logs/$_name.log" 2> /dev/null; then
			echo "node $_name online (pid $(cat "$T4_WORK/pids/$_name"))"
			return 0
		fi
		if ! kill -0 "$(cat "$T4_WORK/pids/$_name")" 2> /dev/null; then break; fi
		sleep 0.2
	done
	echo "node $_name did not come online; see $T4_WORK/logs/$_name.log" >&2
	return 1
}

# t4_node_stop <name>: SIGTERM, the clean shutdown.
t4_node_stop() {
	_pid=$(cat "$T4_WORK/pids/$1")
	kill -TERM "$_pid" 2> /dev/null
	for _ in $(seq 1 100); do
		kill -0 "$_pid" 2> /dev/null || { echo "node $1 stopped (SIGTERM)"; return 0; }
		sleep 0.1
	done
	echo "node $1 ignored SIGTERM" >&2
	return 1
}

# t4_node_kill <name>: SIGKILL, an abrupt loss with no shutdown.
t4_node_kill() {
	_pid=$(cat "$T4_WORK/pids/$1")
	kill -KILL "$_pid" 2> /dev/null
	for _ in $(seq 1 100); do
		kill -0 "$_pid" 2> /dev/null || { echo "node $1 killed (SIGKILL, pid $_pid)"; return 0; }
		sleep 0.1
	done
	echo "node $1 survived SIGKILL" >&2
	return 1
}

# t4_wait_prompts <count> <seconds>: wait until the Runtime has received more than <count>
# prompts, which $T4_WORK/fixture/prompts.log counts. Fail after <seconds>.
t4_wait_prompts() {
	_deadline=$(( $(date +%s) + $2 ))
	while [ "$(wc -l < "$T4_WORK/fixture/prompts.log" 2> /dev/null | tr -d ' ')" -le "$1" ]; do
		if [ "$(date +%s)" -ge "$_deadline" ]; then
			echo "the Runtime did not receive a prompt within $2 seconds" >&2
			return 1
		fi
		sleep 0.2
	done
}

# t4_kill_during_call <client-log> <node> <seconds>: freeze <node> (SIGSTOP) while the
# client waits to answer its permission request, wait for the answer, then kill the Node
# <seconds> after it. The approved Workspace call is then in flight to a Node that cannot
# answer. The function fails, and leaves the Node running, when the client never shows the
# request, when the client fails before it shows one, or when the answer does not arrive
# within 30 seconds (T4_WAIT_SECONDS changes the 30). If you interrupt it, it kills the Node, so no Node stays frozen.
t4_kill_during_call() {
	_log=$1 _node=$2 _after=$3
	_node_pid=$(cat "$T4_WORK/pids/$_node")
	_deadline=$(( $(date +%s) + ${T4_WAIT_SECONDS:-30} ))
	until grep -q "permission request 1:" "$_log" 2> /dev/null; do
		if grep -qE "FAILED|TIMED OUT|connection ended" "$_log" 2> /dev/null; then
			echo "the client failed before it showed a permission request; Node $_node was not frozen" >&2
			return 1
		fi
		if [ "$(date +%s)" -ge "$_deadline" ]; then
			echo "no permission request within ${T4_WAIT_SECONDS:-30} seconds; Node $_node was not frozen" >&2
			return 1
		fi
		sleep 0.2
	done
	trap 'kill -KILL "$_node_pid" 2> /dev/null; trap - INT TERM HUP' INT TERM HUP
	kill -STOP "$_node_pid"
	echo "node $_node frozen (SIGSTOP) while the permission request waits"
	_deadline=$(( $(date +%s) + ${T4_WAIT_SECONDS:-30} ))
	until grep -q "answered" "$_log" 2> /dev/null; do
		if [ "$(date +%s)" -ge "$_deadline" ] || grep -qE "FAILED|TIMED OUT|connection ended" "$_log" 2> /dev/null; then
			kill -CONT "$_node_pid" 2> /dev/null
			trap - INT TERM HUP
			echo "the permission request was not answered; node $_node resumed" >&2
			return 1
		fi
		sleep 0.2
	done
	sleep "$_after"
	kill -KILL "$_node_pid" 2> /dev/null
	trap - INT TERM HUP
	echo "node $_node killed (SIGKILL, pid $_node_pid) $_after seconds after the answer"
}

t4_broker_stop() {
	kill -TERM "$(cat "$T4_WORK/pids/broker")" 2> /dev/null && echo "broker stopped"
}

# t4_client <client.mjs options>: drive `gnostic acp` against Node A.
t4_client() {
	GNOSTIC_STATE_HOME="$T4_WORK/client-state" node "$T4_FIXTURES/client.mjs" "$@" -- \
		"$T4_BIN/gnostic" acp --config "$T4_WORK/node-a.json" \
		--host "$T4_BROKER_HOST" --port "$T4_BROKER_PORT" --namespace "$T4_NAMESPACE" \
		--runtime "$T4_RUNTIME_ID" --node "$T4_NODE_A_ID"
}

# Pass this to `client.mjs --on-session`. The client sets T4_SESSION_TIMELINE_ID
# to the Timeline that `session/new` created, and the command attaches Node B's
# Workspace to it.
T4_ATTACH_CMD="$T4_BIN/gnostic-workspace-attach --host $T4_BROKER_HOST --port $T4_BROKER_PORT --namespace $T4_NAMESPACE --workspace $T4_WORKSPACE_ID --timeline \"\$T4_SESSION_TIMELINE_ID\""

# t4_journal <timeline-id>: print the Node A journal path of a Timeline.
t4_journal() {
	echo "$T4_WORK/state-a/timeline-journals/$T4_NODE_A_ID/timeline-$1-v1.jsonl"
}

# t4_session_timeline <state-file>: print the Timeline ID that `client.mjs --state-file` saved.
t4_session_timeline() {
	node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).timelineId)' "$1"
}

# t4_journal_summary <timeline-id>: print one line per journal record, in order. A record
# it cannot read is reported as unsupported and does not stop the listing.
t4_journal_summary() {
	node "$T4_FIXTURES/journal.mjs" summary "$(t4_journal "$1")"
}

# t4_journal_text <timeline-id>: print the bytes of agent_message_chunk text that the
# journal holds, per record and in total.
t4_journal_text() {
	node "$T4_FIXTURES/journal.mjs" text "$(t4_journal "$1")"
}
