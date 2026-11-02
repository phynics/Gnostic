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
# its process ID, start time and command line are in $T4_WORK/pids/<name> and <name>.id.

# Process records. A process ID alone does not identify a process: the system reuses it
# after the process exits. t4_node_start and t4_broker_start therefore record, next to
# the PID in $T4_WORK/pids/<name>, the process's start time and command line in
# $T4_WORK/pids/<name>.id. They take both from `ps -o lstart= -o command= -p <pid>`, which
# works on Linux and macOS and does not need /proc. Every helper that signals a recorded
# process, or refuses because one is alive, checks the record first with _t4_owned.

# _t4_identity <pid>: print the start time and command line of a process. ps prints the
# start time in the shell's time zone and locale, and cuts the command line to COLUMNS, and
# another terminal can differ. So both settings are fixed here, and -ww asks for full width.
_t4_identity() {
	LC_ALL=C TZ=UTC ps -ww -o lstart= -o command= -p "$1" 2> /dev/null
}

# _t4_record <name> <pid>: record the identity of a process we started.
_t4_record() {
	_t4_identity "$2" > "$T4_WORK/pids/$1.id"
}

# _t4_owned <name>: check the record of <name>. It returns 0 and sets _t4_pid when the
# recorded process is alive and still has the recorded start time and command line (a
# frozen process counts as alive). It returns 1 when there is no such process; a stale
# record is cleared. It returns 2 and clears the record, after it says so, when a process
# with that PID is alive but is not the one we started. Nothing is ever signalled here.
_t4_owned() {
	_t4_pid=
	[ -f "$T4_WORK/pids/$1" ] || return 1
	_recorded=$(cat "$T4_WORK/pids/$1")
	if ! kill -0 "$_recorded" 2> /dev/null; then
		rm -f "$T4_WORK/pids/$1" "$T4_WORK/pids/$1.id"
		return 1
	fi
	_now=$(_t4_identity "$_recorded")
	_then=$(cat "$T4_WORK/pids/$1.id" 2> /dev/null)
	if [ -n "$_then" ] && [ "$_now" = "$_then" ]; then
		_t4_pid=$_recorded
		return 0
	fi
	echo "process $_recorded, recorded for $1, is not the process that was started for $1 (it is: $_now); not signalling it, and clearing the record" >&2
	rm -f "$T4_WORK/pids/$1" "$T4_WORK/pids/$1.id"
	return 2
}

# _t4_signal <name> <signal>: send <signal> to the recorded process of <name>, after
# _t4_owned has accepted it. It fails without signalling otherwise.
_t4_signal() {
	_t4_owned "$1" || return 1
	kill -"$2" "$_t4_pid" 2> /dev/null
}

t4_broker_start() {
	if _t4_owned broker; then
		echo "broker is already running (pid $_t4_pid); run t4_broker_stop first" >&2
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
			_t4_record broker "$(cat "$T4_WORK/pids/broker")"
			echo "broker online at $T4_BROKER_HOST:$T4_BROKER_PORT (pid $(cat "$T4_WORK/pids/broker"))"
			return 0
		fi
		sleep 0.2
	done
	_t4_record broker "$(cat "$T4_WORK/pids/broker")"
	echo "broker did not come online; see $T4_WORK/logs/broker.log" >&2
	return 1
}

# t4_node_start <name> <manifest> <state-dir>
t4_node_start() {
	_name=$1 _manifest=$2 _state=$3
	# A second Node with the same configuration and identity would overwrite the recorded
	# process ID and leave the first Node running with no record.
	if _t4_owned "$_name"; then
		echo "node $_name is already running (pid $_t4_pid); run t4_node_stop $_name first" >&2
		return 1
	fi
	mkdir -p "$T4_WORK/logs" "$T4_WORK/pids" "$_state"
	GNOSTIC_STATE_HOME="$_state" "$T4_BIN/gnostic" serve --config "$_manifest" \
		--host "$T4_BROKER_HOST" --port "$T4_BROKER_PORT" --namespace "$T4_NAMESPACE" \
		> "$T4_WORK/logs/$_name.log" 2>&1 &
	echo $! > "$T4_WORK/pids/$_name"
	rm -f "$T4_WORK/pids/$_name.id"
	for _ in $(seq 1 100); do
		if grep -q "advertised objects" "$T4_WORK/logs/$_name.log" 2> /dev/null; then
			# The process has started by now, so its command line is final.
			_t4_record "$_name" "$(cat "$T4_WORK/pids/$_name")"
			echo "node $_name online (pid $(cat "$T4_WORK/pids/$_name"))"
			return 0
		fi
		if ! kill -0 "$(cat "$T4_WORK/pids/$_name")" 2> /dev/null; then break; fi
		sleep 0.2
	done
	# Record a Node that is still alive but not ready, so that t4_node_stop can end it.
	if kill -0 "$(cat "$T4_WORK/pids/$_name")" 2> /dev/null; then _t4_record "$_name" "$(cat "$T4_WORK/pids/$_name")"; fi
	echo "node $_name did not come online; see $T4_WORK/logs/$_name.log" >&2
	return 1
}

# _t4_end <name> <signal> <label> <done message>: signal the recorded process, then wait for
# it to exit. Nothing is signalled when the record is stale or names another process.
_t4_end() {
	_t4_owned "$1"
	case $? in
		0) ;;
		1) echo "$3 is not running"; return 0 ;;
		*) return 0 ;;
	esac
	_ended_pid=$_t4_pid
	kill -"$2" "$_ended_pid" 2> /dev/null
	for _ in $(seq 1 100); do
		if ! kill -0 "$_ended_pid" 2> /dev/null; then
			rm -f "$T4_WORK/pids/$1.id"
			echo "$4" | sed "s/@PID@/$_ended_pid/"
			return 0
		fi
		sleep 0.1
	done
	echo "$3 survived $2" >&2
	return 1
}

# t4_node_stop <name>: SIGTERM, the clean shutdown.
t4_node_stop() {
	_t4_end "$1" TERM "node $1" "node $1 stopped (SIGTERM)"
}

# t4_node_kill <name>: SIGKILL, an abrupt loss with no shutdown.
t4_node_kill() {
	_t4_end "$1" KILL "node $1" "node $1 killed (SIGKILL, pid @PID@)"
}

t4_broker_stop() {
	_t4_end broker TERM "broker" "broker stopped"
}

# t4_wait_prompts <count> <seconds>: wait until the Runtime has received more than <count>
# prompts, which $T4_WORK/fixture/prompts.log counts. Fail after <seconds>, also when the
# log is missing or unreadable, so that `t4_wait_prompts ... && t4_node_kill a` never kills
# without a prompt.
t4_wait_prompts() {
	case $1$2 in '' | *[!0-9]*) echo "usage: t4_wait_prompts <count> <seconds>" >&2; return 2 ;; esac
	_deadline=$(( $(date +%s) + $2 ))
	while :; do
		if [ -r "$T4_WORK/fixture/prompts.log" ]; then
			_seen=$(wc -l < "$T4_WORK/fixture/prompts.log" | tr -d ' ')
			[ "$_seen" -gt "$1" ] 2> /dev/null && return 0
		fi
		if [ "$(date +%s)" -ge "$_deadline" ]; then
			if [ -r "$T4_WORK/fixture/prompts.log" ]; then
				echo "the Runtime did not receive a prompt within $2 seconds" >&2
			else
				echo "the Runtime did not receive a prompt within $2 seconds: $T4_WORK/fixture/prompts.log is missing or unreadable" >&2
			fi
			return 1
		fi
		sleep 0.2
	done
}

# t4_kill_during_call <client-log> <node> <seconds>: freeze <node> (SIGSTOP) while the
# client waits to answer its permission request, wait for the answer, then kill the Node
# <seconds> after it. The approved Workspace call is then in flight to a Node that cannot
# answer. The function fails, and leaves the Node running, when the Node is not running or
# its record names another process, when the client never shows the request, when the
# client fails before it shows one, or when the answer does not arrive within 30 seconds
# (T4_WAIT_SECONDS changes the 30). If you interrupt it, it kills the Node, so no Node
# stays frozen. Every signal goes through _t4_signal, so it never reaches another process.
t4_kill_during_call() {
	_log=$1 _node=$2 _after=$3
	if ! _t4_owned "$_node"; then
		echo "node $_node is not running; nothing was frozen" >&2
		return 1
	fi
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
	trap '_t4_signal "$_node" KILL; trap - INT TERM HUP' INT TERM HUP
	if ! _t4_signal "$_node" STOP; then
		trap - INT TERM HUP
		echo "node $_node is not running; nothing was frozen" >&2
		return 1
	fi
	echo "node $_node frozen (SIGSTOP) while the permission request waits"
	_deadline=$(( $(date +%s) + ${T4_WAIT_SECONDS:-30} ))
	until grep -q "answered" "$_log" 2> /dev/null; do
		if [ "$(date +%s)" -ge "$_deadline" ] || grep -qE "FAILED|TIMED OUT|connection ended" "$_log" 2> /dev/null; then
			_t4_signal "$_node" CONT
			trap - INT TERM HUP
			echo "the permission request was not answered; node $_node resumed" >&2
			return 1
		fi
		sleep 0.2
	done
	sleep "$_after"
	_t4_owned "$_node" && _killed_pid=$_t4_pid
	_t4_signal "$_node" KILL
	trap - INT TERM HUP
	echo "node $_node killed (SIGKILL, pid $_killed_pid) $_after seconds after the answer"
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
