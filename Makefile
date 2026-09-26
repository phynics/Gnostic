SHELL := /bin/sh
IMAGE ?= gnostic-dev
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
WORKDIR := /workspace
CACHE_NAMESPACE ?= swift-6.4.0-linux
# An absolute common dir names the same cache from the main checkout and
# from every worktree; Scripts/gnostic-container.sh derives the same path.
GIT_COMMON_DIR := $(shell git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
REPOSITORY_NAME ?= $(if $(GIT_COMMON_DIR),$(notdir $(patsubst %/.git,%,$(GIT_COMMON_DIR))),$(notdir $(CURDIR)))
BUILD_CACHE_ROOT ?= /tmp/gnostic-swift-build/$(REPOSITORY_NAME)/$(CACHE_NAMESPACE)
BUILD_DIR ?= $(BUILD_CACHE_ROOT)/debug
BUILD_LOCK ?= 1
SPM_CACHE_DIR ?= $(HOME)/.cache/gnostic/swiftpm/$(CACHE_NAMESPACE)
EXTRA_CONTAINER_MOUNTS ?=
SWIFT_CACHE_ARGS := --cache-path /workspace/.swiftpm-cache
# Swift 6.4 makes Swift Build the default. This gate pins the legacy native
# system because Scripts/gnostic-container.sh, Scripts/dev-stack.sh, and the
# container harness still assume the triple-scoped layout; adopting Swift Build
# needs those made layout-independent first. Reconsider when --build-system
# native is removed upstream or the wrappers use --show-bin-path (#266).
SWIFT_BUILD_SYSTEM_ARGS := --build-system native
SWIFT_LOCKED_ARGS := $(SWIFT_CACHE_ARGS) --disable-automatic-resolution $(SWIFT_BUILD_SYSTEM_ARGS)
SWIFT_WARNING_ARGS := --quiet -Xswiftc -warnings-as-errors

DEV_BROKER_PORT ?= 1884
DEV_STACK_ENV = CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" GNOSTIC_IMAGE="$(IMAGE)" GNOSTIC_BUILD_ROOT="$(BUILD_DIR)" DEV_BROKER_PORT="$(DEV_BROKER_PORT)"

.PHONY: help image require-package resolve worktree-bootstrap build test benchmark scenario-stage0 scenario-stage1 scenario-live scenario-live-preflight docs-check lint harness-test runner-smoke acp-backend-test acp-smoke container-smoke macos-rlm-smoke verify shell clean dev-up dev-status dev-down sbom

help:
	@echo "Targets: image require-package resolve worktree-bootstrap build test benchmark scenario-stage0 scenario-stage1 scenario-live scenario-live-preflight docs-check lint harness-test runner-smoke acp-backend-test acp-smoke container-smoke macos-rlm-smoke verify shell clean dev-up dev-status dev-down sbom"

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
	@git rev-parse HEAD > "$(BUILD_DIR)/gnostic-build-revision" 2>/dev/null || rm -f "$(BUILD_DIR)/gnostic-build-revision"

test: build
	@mkdir -p .testing
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'set -e; pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d; npm ci --prefix Tests/Fixtures/ACPAgent --cache .testing/npm-cache; bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --show-bin-path)/gnostic; test -x "$$bin" || { echo "Could not locate built gnostic executable at $$bin" >&2; exit 1; }; GNOSTIC_ACP_AGENT_FIXTURE=/workspace/Tests/Fixtures/ACPAgent/agent.mjs GNOSTIC_SERVE_BINARY="$$bin" GNOSTIC_CLI_BINARY="$$bin" swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --no-parallel | tee .testing/swift-test.log; grep -Eq "Test run with [1-9][0-9]* tests" .testing/swift-test.log; grep -F "Suite \"ACP Ascendant backend\" passed" .testing/swift-test.log'

benchmark: require-package image
	@mkdir -p Documentation/Experiments
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'git config --global --add safe.directory /workspace; swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-rlm-benchmark; bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-rlm-benchmark --show-bin-path)/gnostic-rlm-benchmark; test -x "$$bin" || { echo "Could not locate benchmark executable at $$bin" >&2; exit 1; }; GNOSTIC_BENCHMARK_COMMIT=$$(git rev-parse HEAD) "$$bin" | tee Documentation/Experiments/rlm-runtime-benchmark.json'

scenario-stage0: build
	@mkdir -p Documentation/Experiments
	@commit="$$(git rev-parse HEAD)"; image_digest="$$($(CONTAINER_RUNTIME) image inspect "$(IMAGE)" --format '{{.Id}}')"; \
		BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" \
		./.devcontainer/run.sh bash -o pipefail -c "export GNOSTIC_SCENARIO_COMMIT='$$commit' GNOSTIC_SCENARIO_IMAGE_DIGEST='$$image_digest'; bash /workspace/Scripts/run-rlm-scenario-stage0.sh"

scenario-stage1: require-package
	@bash Scripts/run-rlm-scenario-stage1.sh

scenario-live: build
	@CONFIG="$(CONFIG)" ARGS="$(ARGS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" SWIFT_LOCKED_ARGS="$(SWIFT_LOCKED_ARGS)" \
		BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" \
		bash Scripts/run-rlm-scenario-live.sh

# Validates the live-stage handoff (executors start, no provider contacted)
# with a throwaway Ollama-backed manifest. No spend, no credentials needed.
scenario-live-preflight: build
	@IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" SWIFT_LOCKED_ARGS="$(SWIFT_LOCKED_ARGS)" \
		BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" \
		bash Scripts/rlm-scenario-live-preflight.sh

docs-check: build
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'node /workspace/Scripts/check-documentation.mjs --self-test; bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --show-bin-path)/gnostic; test -x "$$bin" || { echo "Could not locate built gnostic executable at $$bin" >&2; exit 1; }; node /workspace/Scripts/check-documentation.mjs --root /workspace --cli "$$bin"'

lint: require-package
	@./Scripts/check-unchecked-sendable.sh

harness-test:
	@./Tests/Support/test-run-container.sh
	@./Tests/Support/test-gnostic-container.sh

runner-smoke: require-package image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'set -e; test ! -e Sources/GnosticRunner/FixtureScenario.swift; test ! -e Sources/GnosticRunner/RunnerError.swift; package=$$(swift package dump-package $(SWIFT_LOCKED_ARGS)); printf "%s\\n" "$$package" | node -e "let data=\"\"; process.stdin.on(\"data\", chunk => data += chunk); process.stdin.on(\"end\", () => { const target = JSON.parse(data).targets.find(({ name }) => name === \"GnosticRunner\"); const dependencies = JSON.stringify(target?.dependencies ?? []); if (!target || /PositronicKit|PKContracts/.test(dependencies)) process.exit(1); });"; bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-runner --show-bin-path)/gnostic-runner; test -x "$$bin"; help=$$("$$bin" --help 2>&1); status=$$?; printf "%s\\n" "$$help" && test $$status -eq 0 && ! (printf "%s\\n" "$$help" | grep -F -- "--scenario"); pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d; runner_output=$$(mktemp); runner_pid=; cleanup() { if test -n "$$runner_pid"; then kill "$$runner_pid" 2>/dev/null || true; fi; rm -f "$$runner_output"; }; trap cleanup EXIT INT TERM; stdbuf -oL "$$bin" --host 127.0.0.1 --port 1883 --namespace gnostic-smoke >"$$runner_output" 2>&1 & runner_pid=$$!; status=1; for i in $$(seq 1 30); do if grep -F "gnostic-runner online at" "$$runner_output" >/dev/null 2>&1; then status=0; break; fi; if ! kill -0 "$$runner_pid" 2>/dev/null; then break; fi; sleep 1; done; output=$$(<"$$runner_output"); printf "%s\\n" "$$output"; test $$status -eq 0 && printf "%s\\n" "$$output" | grep -F "gnostic-runner online at"'

acp-smoke: require-package image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'set -e; pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d; npm ci --prefix Tests/Fixtures/OfficialACPClient --cache .testing/npm-cache; npm ci --legacy-peer-deps --prefix Tests/Fixtures/PiACPClient --cache .testing/npm-cache; npm ci --prefix Tests/Fixtures/ACPAgent --cache .testing/npm-cache; bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic --show-bin-path)/gnostic; test -x "$$bin" || { echo "Could not locate built gnostic executable at $$bin" >&2; exit 1; }; GNOSTIC_ACP_AGENT_FIXTURE=/workspace/Tests/Fixtures/ACPAgent/agent.mjs timeout --signal=TERM --kill-after=5s 120s swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --filter GnosticACPAscendantTests | tee .testing/acp-backend-smoke.log; grep -F "Suite \"ACP Ascendant backend\" passed" .testing/acp-backend-smoke.log; GNOSTIC_ACP_BINARY="$$bin" GNOSTIC_ACP_OFFICIAL_CLIENT=/workspace/Tests/Fixtures/OfficialACPClient/lifecycle.mjs GNOSTIC_PI_ACP_CLIENT_FIXTURE=/workspace/Tests/Fixtures/PiACPClient/lifecycle.mjs timeout --signal=TERM --kill-after=5s 120s swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --filter GnosticCLITests.ACPSubprocessTests | tee .testing/acp-smoke.log; grep -F "Test run with 5 tests" .testing/acp-smoke.log'

acp-backend-test: require-package image
	@mkdir -p .testing
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'set -e; npm ci --prefix Tests/Fixtures/ACPAgent --cache .testing/npm-cache; swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic; GNOSTIC_ACP_AGENT_FIXTURE=/workspace/Tests/Fixtures/ACPAgent/agent.mjs timeout --signal=TERM --kill-after=5s 120s swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --filter GnosticACPAscendantTests | tee .testing/acp-backend-tests.log; grep -F "Suite \"ACP Ascendant backend\" passed" .testing/acp-backend-tests.log; grep -Eq "Test run with [1-9][0-9]* tests" .testing/acp-backend-tests.log'

container-smoke: image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh /workspace/Scripts/container-smoke.sh

macos-rlm-smoke: require-package
	@bash Scripts/macos-rlm-smoke.sh

# Release-time SBOM for the SwiftPM dependency graph. Not part of verify: the
# output embeds a random serial number and creation timestamp, and SwiftPM
# warns that it omits build-time conditionals and does not cover the
# container's system packages. See README "Generate an SBOM".
sbom: require-package image
	@mkdir -p .testing/sbom
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'rm -rf .testing/sbom; mkdir -p .testing/sbom; swift package generate-sbom --cache-path /workspace/.swiftpm-cache --sbom-spec spdx --sbom-spec cyclonedx --sbom-output-dir .testing/sbom && ls -1 .testing/sbom'

verify: docs-check lint test

shell: image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash

dev-up: build
	@$(DEV_STACK_ENV) ./Scripts/dev-stack.sh up

dev-status:
	@$(DEV_STACK_ENV) ./Scripts/dev-stack.sh status

dev-down:
	@$(DEV_STACK_ENV) ./Scripts/dev-stack.sh down

clean:
	@rm -rf "$(BUILD_CACHE_ROOT)" .swiftpm-cache .testing
