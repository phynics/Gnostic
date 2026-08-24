SHELL := /bin/sh
IMAGE ?= gnostic-dev
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
WORKDIR := /workspace
CACHE_NAMESPACE ?= swift-6.3.3-linux
REPOSITORY_NAME ?= $(shell git rev-parse --git-common-dir 2>/dev/null | sed 's|/.git$$||' | xargs basename 2>/dev/null || basename "$(CURDIR)")
BUILD_CACHE_ROOT ?= /tmp/gnostic-swift-build/$(REPOSITORY_NAME)/$(CACHE_NAMESPACE)
BUILD_DIR ?= $(BUILD_CACHE_ROOT)/debug
BUILD_LOCK ?= 1
SPM_CACHE_DIR ?= $(HOME)/.cache/gnostic/swiftpm/$(CACHE_NAMESPACE)
EXTRA_CONTAINER_MOUNTS ?=
SWIFT_CACHE_ARGS := --cache-path /workspace/.swiftpm-cache
SWIFT_LOCKED_ARGS := $(SWIFT_CACHE_ARGS) --disable-automatic-resolution
SWIFT_WARNING_ARGS := --quiet -Xswiftc -warnings-as-errors

.PHONY: help image require-package resolve worktree-bootstrap build test docs-check runner-smoke acp-smoke container-smoke verify shell clean

help:
	@echo "Targets: image require-package resolve worktree-bootstrap build test docs-check runner-smoke acp-smoke container-smoke verify shell clean"

image:
	@if [ "$(GNOSTIC_DEVCONTAINER)" = "1" ]; then :; else \
		test -n "$(CONTAINER_RUNTIME)" || { echo "No podman or docker runtime found" >&2; exit 1; }; \
		"$(CONTAINER_RUNTIME)" build -t "$(IMAGE)" -f .devcontainer/Dockerfile .; \
	fi

require-package:
	@test -f Package.swift || { echo "Package.swift is not present on this branch" >&2; exit 2; }

resolve: require-package image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh ./.devcontainer/resolve.sh

worktree-bootstrap: resolve

build: require-package image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS)

test: build
	@mkdir -p .testing
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d; GNOSTIC_SERVE_BINARY=/workspace/.build/x86_64-unknown-linux-gnu/debug/gnostic GNOSTIC_CLI_BINARY=/workspace/.build/x86_64-unknown-linux-gnu/debug/gnostic swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) | tee .testing/swift-test.log && grep -Eq "Test run with [1-9][0-9]* tests" .testing/swift-test.log'

docs-check: build
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'node /workspace/Scripts/check-documentation.mjs --self-test; bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --show-bin-path)/gnostic; test -x "$$bin" || { echo "Could not locate built gnostic executable at $$bin" >&2; exit 1; }; node /workspace/Scripts/check-documentation.mjs --root /workspace --cli "$$bin"'

runner-smoke: require-package image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'test ! -e Sources/GnosticRunner/FixtureScenario.swift && test ! -e Sources/GnosticRunner/RunnerError.swift; package=$$(swift package dump-package $(SWIFT_LOCKED_ARGS)); printf "%s\\n" "$$package" | node -e "let data=\"\"; process.stdin.on(\"data\", chunk => data += chunk); process.stdin.on(\"end\", () => { const target = JSON.parse(data).targets.find(({ name }) => name === \"GnosticRunner\"); const dependencies = JSON.stringify(target?.dependencies ?? []); if (!target || /PositronicKit|PKContracts/.test(dependencies)) process.exit(1); });"; bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-runner --show-bin-path)/gnostic-runner; test -x "$$bin"; help=$$("$$bin" --help 2>&1); status=$$?; printf "%s\\n" "$$help" && test $$status -eq 0 && ! (printf "%s\\n" "$$help" | grep -F -- "--scenario"); pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d; runner_output=$$(mktemp); runner_pid=; cleanup() { if test -n "$$runner_pid"; then kill "$$runner_pid" 2>/dev/null || true; fi; rm -f "$$runner_output"; }; trap cleanup EXIT INT TERM; stdbuf -oL "$$bin" --host 127.0.0.1 --port 1883 --namespace gnostic-smoke >"$$runner_output" 2>&1 & runner_pid=$$!; status=1; for i in $$(seq 1 30); do if grep -F "gnostic-runner online at" "$$runner_output" >/dev/null 2>&1; then status=0; break; fi; if ! kill -0 "$$runner_pid" 2>/dev/null; then break; fi; sleep 1; done; output=$$(<"$$runner_output"); printf "%s\\n" "$$output"; test $$status -eq 0 && printf "%s\\n" "$$output" | grep -F "gnostic-runner online at"'

acp-smoke: require-package image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d; npm ci --prefix Tests/Fixtures/OfficialACPClient --cache .testing/npm-cache; npm ci --legacy-peer-deps --prefix Tests/Fixtures/PiACPClient --cache .testing/npm-cache; GNOSTIC_ACP_BINARY=/workspace/.build/x86_64-unknown-linux-gnu/debug/gnostic GNOSTIC_ACP_OFFICIAL_CLIENT=/workspace/Tests/Fixtures/OfficialACPClient/lifecycle.mjs GNOSTIC_PI_ACP_CLIENT_FIXTURE=/workspace/Tests/Fixtures/PiACPClient/lifecycle.mjs swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --filter GnosticCLITests.ACPSubprocessTests | tee .testing/acp-smoke.log && grep -F "Test run with 4 tests" .testing/acp-smoke.log'

container-smoke: image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh /workspace/Scripts/container-smoke.sh

verify: docs-check test

shell: image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash

clean:
	@rm -rf "$(BUILD_CACHE_ROOT)" .swiftpm-cache .testing
