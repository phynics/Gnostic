#!/bin/sh
# Local ACP test stack: a dedicated broker, a scratch Node manifest,
# `gnostic serve`, and a pi-acp-client profile config. Use it through
# `make dev-up`, `make dev-status`, and `make dev-down`.

set -eu

runtime=${CONTAINER_RUNTIME:-podman}
image=${GNOSTIC_IMAGE:-gnostic-dev}
build_root=${GNOSTIC_BUILD_ROOT:?set GNOSTIC_BUILD_ROOT or run through make dev-up}
seed_config=${GNOSTIC_DEV_CONFIG:-$HOME/.gnostic/config.json}
stack_dir=${GNOSTIC_DEV_STACK_DIR:-$HOME/.gnostic/dev/stack}
broker=gnostic-dev-broker
serve=gnostic-dev-serve
binary=/workspace/.build/x86_64-unknown-linux-gnu/debug/gnostic

die() {
    echo "dev-stack: $*" >&2
    exit 1
}

running() {
    "$runtime" inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true
}

# Polls a readiness check once per second; shows the container log on failure.
wait_for() {
    name=$1
    seconds=$2
    container=$3
    shift 3
    elapsed=0
    while [ "$elapsed" -lt "$seconds" ]; do
        if "$@"; then
            return 0
        fi
        running "$container" || break
        sleep 1
        elapsed=$((elapsed + 1))
    done
    "$runtime" logs "$container" 2>&1 | tail -n 20 >&2
    die "$name did not become ready"
}

broker_ready() {
    "$runtime" exec "$broker" mosquitto_pub -h 127.0.0.1 -p "$port" -t gnostic/dev/ping -n >/dev/null 2>&1
}

serve_ready() {
    "$runtime" logs "$serve" 2>&1 | grep -q 'gnostic serve online at'
}

# Prints one "id  name" line per Ascendant profile discovered on the stack.
list_profiles() {
    json=$("$runtime" run --rm --network host -v "$build_root:/workspace/.build:ro" "$image" \
        "$binary" acp profiles --json --refresh --host 127.0.0.1 --port "$port" --namespace "$namespace") || return 1
    printf '%s' "$json" | node -e '
        let input = "";
        process.stdin.on("data", (chunk) => input += chunk).on("end", () => {
            for (const profile of JSON.parse(input).profiles) console.log(`  ${profile.id}  ${profile.name}`);
        });'
}

load_stack() {
    test -f "$stack_dir/stack.env" || die "no dev stack exists; run 'make dev-up'"
    . "$stack_dir/stack.env"
}

remove_stack() {
    # Stop serve first so it can deadvertise while the broker is still up.
    "$runtime" stop -t 10 "$serve" >/dev/null 2>&1 || true
    "$runtime" rm -f "$serve" "$broker" >/dev/null 2>&1 || true
    if [ -f "$stack_dir/stack.env" ]; then
        rm -rf "$stack_dir"
    fi
}

up() {
    test ! -e "$stack_dir/stack.env" || die "a dev stack already exists in $stack_dir; run 'make dev-down' first"
    command -v "$runtime" >/dev/null 2>&1 || die "container runtime '$runtime' was not found"
    command -v node >/dev/null 2>&1 || die "node is required to read discovered profiles"
    test -x "$build_root/x86_64-unknown-linux-gnu/debug/gnostic" || die "Gnostic is not built in $build_root; run 'make build'"
    if running "$broker" || running "$serve"; then
        die "dev stack containers are already running; run 'make dev-down' first"
    fi

    port=${DEV_BROKER_PORT:-1884}
    namespace=dev-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
    mkdir -p "$stack_dir/broker"
    chmod 700 "$stack_dir"
    printf 'namespace=%s\nport=%s\n' "$namespace" "$port" >"$stack_dir/stack.env"
    ready=0
    trap 'if [ "$ready" -ne 1 ]; then remove_stack; fi' EXIT

    printf '%s\n' "listener $port 127.0.0.1" 'allow_anonymous true' 'persistence false' 'log_dest stderr' \
        >"$stack_dir/broker/mosquitto.conf"
    "$runtime" rm -f "$broker" "$serve" >/dev/null 2>&1 || true
    "$runtime" run -d --name "$broker" --network host -v "$stack_dir/broker:/broker:ro" "$image" \
        mosquitto -c /broker/mosquitto.conf >/dev/null
    wait_for "broker on 127.0.0.1:$port" 15 "$broker" broker_ready

    if [ -f "$seed_config" ]; then
        # The dedicated broker is anonymous; seeded broker credentials would
        # only make it reject the connection.
        node -e '
            const fs = require("node:fs");
            const [source, destination] = process.argv.slice(1);
            const manifest = JSON.parse(fs.readFileSync(source, "utf8"));
            if (manifest.broker) {
                delete manifest.broker.username;
                delete manifest.broker.password;
            }
            fs.writeFileSync(destination, JSON.stringify(manifest, null, 2) + "\n", { mode: 0o600 });' \
            "$seed_config" "$stack_dir/config.json"
        manifest_source="copied from $seed_config without broker credentials"
    else
        "$runtime" run --rm -v "$build_root:/workspace/.build:ro" -v "$stack_dir:/stack" "$image" \
            "$binary" config init --config /stack/config.json >/dev/null
        manifest_source="new default manifest"
    fi

    "$runtime" run -d --name "$serve" --network host \
        -v "$build_root:/workspace/.build:ro" -v "$stack_dir:/stack" "$image" \
        stdbuf -oL "$binary" serve --config /stack/config.json \
        --host 127.0.0.1 --port "$port" --namespace "$namespace" >/dev/null
    wait_for "gnostic serve" 60 "$serve" serve_ready

    profiles=""
    attempts=0
    while [ -z "$profiles" ] && [ "$attempts" -lt 5 ]; do
        profiles=$(list_profiles) || profiles=""
        attempts=$((attempts + 1))
    done
    test -n "$profiles" || die "gnostic serve is online but no Ascendant profile was discovered on $namespace"

    cat >"$stack_dir/acp-profiles.json" <<EOF
{
  "version": 1,
  "profiles": [],
  "sources": [
    {
      "command": "gnostic",
      "args": ["acp", "profiles", "--json", "--host", "127.0.0.1", "--port", "$port", "--namespace", "$namespace"]
    }
  ]
}
EOF
    ready=1

    echo "Gnostic dev stack ready"
    echo "  broker     127.0.0.1:$port (container $broker)"
    echo "  namespace  $namespace"
    echo "  manifest   $stack_dir/config.json ($manifest_source)"
    echo "  serve log  $runtime logs -f $serve"
    echo "  profiles"
    echo "$profiles"
    echo
    echo "Launch pi with:"
    echo "  PI_ACP_CONFIG=$stack_dir/acp-profiles.json pi"
    echo
    echo "pi starts profiles with 'gnostic' from PATH (Scripts/gnostic-container.sh)."
    echo "Relaunch pi after restarting serve: provider IDs change with every serve process."
    if ! command -v gnostic >/dev/null 2>&1; then
        echo "warning: 'gnostic' is not on PATH; link Scripts/gnostic-container.sh into PATH" >&2
    fi
}

status() {
    load_stack
    echo "namespace $namespace, broker 127.0.0.1:$port"
    for container in "$broker" "$serve"; do
        state=$("$runtime" inspect -f '{{.State.Status}}' "$container" 2>/dev/null) || state=missing
        printf '  %-20s %s\n' "$container" "$state"
    done
    profiles=$(list_profiles) || die "profile discovery failed"
    test -n "$profiles" || die "no Ascendant profile was discovered on $namespace"
    echo "profiles"
    echo "$profiles"
    echo "PI_ACP_CONFIG=$stack_dir/acp-profiles.json pi"
}

down() {
    if [ ! -f "$stack_dir/stack.env" ] && ! running "$broker" && ! running "$serve"; then
        echo "No dev stack is running"
        return 0
    fi
    remove_stack
    echo "Gnostic dev stack removed"
}

case ${1:-} in
    up) up ;;
    status) status ;;
    down) down ;;
    *) die "usage: $0 up|status|down" ;;
esac
