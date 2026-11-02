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

t4_broker_start() {
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

# t4_journal_summary <timeline-id>: print one line per journal record, in order.
t4_journal_summary() {
	node -e '
		const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
		for (const [index, line] of lines.entries()) {
			const record = JSON.parse(line.slice(line.indexOf("{")));
			const kind = Object.keys(record.payload)[0];
			const body = record.payload[kind];
			// An acpUpdate stores the frame text exactly as the Runtime sent it (#730).
			const stored = body.update?.update;
			const frame = typeof stored === "string" ? JSON.parse(stored) : stored;
			const update = frame?.params?.update ?? frame;
			const detail = kind === "acpUpdate" ? (update?.sessionUpdate ?? "")
				: kind === "sessionTransition" ? body.state
				: kind === "turnCompleted" ? body.outcome
				: kind === "permissionDecision" ? body.decision
				: kind === "workspaceAttached" ? body.scope
				: "";
			console.log([String(index + 1).padStart(3), "seq=" + record.sequence, kind, detail].filter(Boolean).join(" "));
		}' "$(t4_journal "$1")"
}

# t4_journal_text <timeline-id>: print the bytes of agent_message_chunk text that the
# journal holds, per record and in total.
t4_journal_text() {
	node -e '
		let total = 0, count = 0;
		for (const line of require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n")) {
			const record = JSON.parse(line.slice(line.indexOf("{")));
			const stored = record.payload.acpUpdate?.update?.update;
			const frame = typeof stored === "string" ? JSON.parse(stored) : stored;
			const update = frame?.params?.update ?? frame;
			if (update?.sessionUpdate !== "agent_message_chunk") continue;
			const block = Array.isArray(update.content) ? update.content[0] : update.content;
			total += Buffer.byteLength(block.text); count += 1;
			console.log("journal seq=" + record.sequence, "agent_message_chunk", Buffer.byteLength(block.text), "bytes");
		}
		console.log("journal: agent text", total, "bytes in", count, "chunks");' "$(t4_journal "$1")"
}
