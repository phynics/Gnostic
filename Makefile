SHELL := /bin/sh
IMAGE ?= gnostic-dev:$(shell ./.devcontainer/image-fingerprint.sh .)
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
WORKDIR := /workspace
SWIFT_BUILD_SYSTEM ?= native
SWIFT_TOOLCHAIN_VERSION ?= $(shell ./Scripts/gnostic-build-path.sh swift-version)
CACHE_NAMESPACE ?= swift-$(SWIFT_TOOLCHAIN_VERSION)-linux
BUILD_CONFIGURATION ?= debug
BUILD_REPOSITORY_ID ?= $(shell ./Scripts/gnostic-build-path.sh repository-id)
BUILD_WORKTREE_ID ?= $(shell ./Scripts/gnostic-build-path.sh worktree-id)
BUILD_TARGET_PLATFORM ?= $(shell ./Scripts/gnostic-build-path.sh platform)
BUILD_CACHE_ROOT ?= /tmp/gnostic-swift-build/$(BUILD_REPOSITORY_ID)/$(CACHE_NAMESPACE)-$(SWIFT_BUILD_SYSTEM)-$(BUILD_TARGET_PLATFORM)/worktrees/$(BUILD_WORKTREE_ID)
BUILD_DIR ?= $(BUILD_CACHE_ROOT)/$(BUILD_CONFIGURATION)
BUILD_LOCK_TIMEOUT ?= 1800
CONTAINER_TIMEOUT ?= 3600
SPM_CACHE_DIR ?= $(HOME)/.cache/gnostic/swiftpm/$(CACHE_NAMESPACE)
EXTRA_CONTAINER_MOUNTS ?=
SWIFT_CACHE_ARGS := --cache-path /workspace/.swiftpm-cache
# Keep SwiftPM's native build system pinned to the decision in #266. The
# wrappers now consume validated `--show-bin-path` metadata, so their executable
# lookup no longer depends on native's triple-scoped layout.
SWIFT_BUILD_SYSTEM_ARGS := --build-system $(SWIFT_BUILD_SYSTEM)
SWIFT_CONFIGURATION_ARGS := $(if $(filter debug,$(BUILD_CONFIGURATION)),,-c $(BUILD_CONFIGURATION))
SWIFT_LOCKED_ARGS := $(SWIFT_CACHE_ARGS) --disable-automatic-resolution $(SWIFT_BUILD_SYSTEM_ARGS) $(SWIFT_CONFIGURATION_ARGS)
SWIFT_WARNING_ARGS := --quiet -Xswiftc -warnings-as-errors
ACP_TEST_FILTER ?= GnosticACPAscendantTests
FILTER ?=
N ?= 5
TEST_TIMEOUT ?= 3600

DEV_BROKER_PORT ?= 1884
DEV_STACK_ENV = CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" GNOSTIC_IMAGE="$(IMAGE)" GNOSTIC_BUILD_ROOT="$(BUILD_DIR)" BUILD_LOCK_TIMEOUT="$(BUILD_LOCK_TIMEOUT)" DEV_BROKER_PORT="$(DEV_BROKER_PORT)"
CONTAINER_RUN_ENV = BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK_TIMEOUT="$(BUILD_LOCK_TIMEOUT)" CONTAINER_TIMEOUT="$(CONTAINER_TIMEOUT)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" EXTRA_CONTAINER_ENV="$(EXTRA_CONTAINER_ENV)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)"

.PHONY: help image require-package require-build-configuration require-filter require-repeat-count require-test-timeout resolve worktree-bootstrap build test test-one test-one-repeat benchmark scenario-stage0 scenario-stage1 scenario-live scenario-live-preflight docs-check lint harness-test runner-smoke acp-backend-test acp-smoke acp-live-smoke container-smoke macos-rlm-smoke macos-product-proof soak verify shell clean dev-up dev-status dev-down sbom

help:
	@echo "Targets: image require-package resolve worktree-bootstrap build test test-one test-one-repeat benchmark scenario-stage0 scenario-stage1 scenario-live scenario-live-preflight docs-check lint harness-test runner-smoke acp-backend-test acp-smoke acp-live-smoke container-smoke macos-rlm-smoke macos-product-proof soak verify shell clean dev-up dev-status dev-down sbom"

image:
	@CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" IMAGE="$(IMAGE)" ./.devcontainer/build-image.sh "$(CONTAINER_RUNTIME)" "$(IMAGE)" .

require-package:
	@test -f Package.swift || { echo "Package.swift is not present on this branch" >&2; exit 2; }

require-build-configuration:
	@case "$(BUILD_CONFIGURATION)" in debug|release) ;; *) echo "BUILD_CONFIGURATION must be debug or release, got: $(BUILD_CONFIGURATION)" >&2; exit 2 ;; esac

require-filter:
	@test -n "$(FILTER)" || { echo "Set FILTER to a Swift test name or suite name" >&2; exit 2; }

require-repeat-count:
	@case "$(N)" in ''|*[!0-9]*|0*) echo "N must be a positive integer without leading zeroes, got: $(N)" >&2; exit 2 ;; esac

require-test-timeout:
	@case "$(TEST_TIMEOUT)" in ''|*[!0-9]*|0*) echo "TEST_TIMEOUT must be a positive integer without leading zeroes, got: $(TEST_TIMEOUT)" >&2; exit 2 ;; esac

resolve: require-package image
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh ./.devcontainer/resolve.sh

worktree-bootstrap: resolve

build: require-package require-build-configuration image
	@GNOSTIC_BUILD_REVISION="$$(git rev-parse HEAD)" $(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash -o pipefail -c 'set -e; swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic; bin_dir=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --show-bin-path); case "$$bin_dir" in /workspace/.build/*) ;; *) echo "Unexpected SwiftPM executable directory: $$bin_dir" >&2; exit 1 ;; esac; printf "%s\n" "$$bin_dir/gnostic" > .build/gnostic-bin-path; printf "%s\n" "$${GNOSTIC_BUILD_REVISION:?}" > .build/gnostic-build-revision'

test: build
	@mkdir -p .testing
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash -o pipefail -c 'set -e; pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d; npm ci --prefix Tests/Fixtures/ACPAgent --cache .build/npm-cache; bin=$$(cat .build/gnostic-bin-path); test -x "$$bin" || { echo "Could not locate built gnostic executable at $$bin" >&2; exit 1; }; runtime_bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-pk-runtime --show-bin-path)/gnostic-pk-runtime; test -x "$$runtime_bin" || { echo "Could not locate gnostic-pk-runtime at $$runtime_bin" >&2; exit 1; }; GNOSTIC_PK_RUNTIME_BINARY="$$runtime_bin" GNOSTIC_ACP_AGENT_FIXTURE=/workspace/Tests/Fixtures/ACPAgent/agent.mjs GNOSTIC_SERVE_BINARY="$$bin" GNOSTIC_CLI_BINARY="$$bin" swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --no-parallel | tee .testing/swift-test.log; grep -Eq "Test run with [1-9][0-9]* tests" .testing/swift-test.log; GNOSTIC_ACP_AGENT_FIXTURE=/workspace/Tests/Fixtures/ACPAgent/agent.mjs timeout --signal=TERM --kill-after=5s 120s swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --skip-build --filter GnosticACPAscendantTests | tee .testing/acp-backend-verify.log; grep -Eq "Test run with [1-9][0-9]* tests" .testing/acp-backend-verify.log'

test-one: require-package require-build-configuration require-filter require-test-timeout image
	@FILTER="$(FILTER)" N=1 TEST_TIMEOUT="$(TEST_TIMEOUT)" SWIFT_FLAGS="$(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS)" $(CONTAINER_RUN_ENV) ./.devcontainer/run.sh /workspace/Scripts/run-focused-tests.sh

test-one-repeat: require-package require-build-configuration require-filter require-repeat-count require-test-timeout image
	@FILTER="$(FILTER)" N="$(N)" TEST_TIMEOUT="$(TEST_TIMEOUT)" SWIFT_FLAGS="$(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS)" $(CONTAINER_RUN_ENV) ./.devcontainer/run.sh /workspace/Scripts/run-focused-tests.sh

benchmark: require-package require-build-configuration image
	@mkdir -p Documentation/Experiments
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash -o pipefail -c 'git config --global --add safe.directory /workspace; swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-rlm-benchmark; bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-rlm-benchmark --show-bin-path)/gnostic-rlm-benchmark; test -x "$$bin" || { echo "Could not locate benchmark executable at $$bin" >&2; exit 1; }; GNOSTIC_BENCHMARK_COMMIT=$$(git rev-parse HEAD) "$$bin" | tee Documentation/Experiments/rlm-runtime-benchmark.json'

scenario-stage0: build
	@mkdir -p Documentation/Experiments
	@commit="$$(git rev-parse HEAD)"; image_digest="$$($(CONTAINER_RUNTIME) image inspect "$(IMAGE)" --format '{{.Id}}')"; \
		$(CONTAINER_RUN_ENV) \
		./.devcontainer/run.sh bash -o pipefail -c "export GNOSTIC_SCENARIO_COMMIT='$$commit' GNOSTIC_SCENARIO_IMAGE_DIGEST='$$image_digest'; bash /workspace/Scripts/run-rlm-scenario-stage0.sh"

scenario-stage1: require-package
	@bash Scripts/run-rlm-scenario-stage1.sh

scenario-live: build
	@CONFIG="$(CONFIG)" ARGS="$(ARGS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" SWIFT_LOCKED_ARGS="$(SWIFT_LOCKED_ARGS)" \
		BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK_TIMEOUT="$(BUILD_LOCK_TIMEOUT)" CONTAINER_TIMEOUT="$(CONTAINER_TIMEOUT)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" \
		bash Scripts/run-rlm-scenario-live.sh

# Validates the live-stage handoff (executors start, no provider contacted)
# with a throwaway Ollama-backed manifest. No spend, no credentials needed.
scenario-live-preflight: build
	@IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" SWIFT_LOCKED_ARGS="$(SWIFT_LOCKED_ARGS)" \
		BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK_TIMEOUT="$(BUILD_LOCK_TIMEOUT)" CONTAINER_TIMEOUT="$(CONTAINER_TIMEOUT)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" \
		bash Scripts/rlm-scenario-live-preflight.sh

docs-check: build
	@EXTRA_CONTAINER_ENV="-e GH_TOKEN -e GITHUB_TOKEN" $(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash -o pipefail -c 'set -e; swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-experiment; node /workspace/Scripts/check-documentation.mjs --self-test; bin=$$(cat .build/gnostic-bin-path); test -x "$$bin" || { echo "Could not locate built gnostic executable at $$bin" >&2; exit 1; }; node /workspace/Scripts/check-documentation.mjs --root /workspace --cli "$$bin"'

lint: require-package
	@./Scripts/check-unchecked-sendable.sh

harness-test:
	@./Tests/Support/test-run-container.sh
	@./Tests/Support/test-gnostic-container.sh
	@./Tests/Support/test-build-isolation.sh
	@./Tests/Support/test-soak.sh

runner-smoke: require-package require-build-configuration image
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash -o pipefail -c 'set -e; npm ci --prefix Tests/Fixtures/ACPAgent --cache .build/npm-cache; /workspace/Scripts/runner-smoke.sh'

acp-smoke: build
	@mkdir -p .testing
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash -o pipefail -c 'set -e; pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d; npm ci --prefix Tests/Fixtures/OfficialACPClient --cache .build/npm-cache; npm ci --legacy-peer-deps --prefix Tests/Fixtures/PiACPClient --cache .build/npm-cache; npm ci --prefix Tests/Fixtures/ACPAgent --cache .build/npm-cache; bin=$$(cat .build/gnostic-bin-path); test -x "$$bin" || { echo "Could not locate built gnostic executable at $$bin" >&2; exit 1; }; runtime_bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-pk-runtime --show-bin-path)/gnostic-pk-runtime; test -x "$$runtime_bin" || { echo "Could not locate gnostic-pk-runtime at $$runtime_bin" >&2; exit 1; }; swift build $(SWIFT_LOCKED_ARGS) --build-tests; GNOSTIC_PK_RUNTIME_BINARY="$$runtime_bin" timeout --signal=TERM --kill-after=5s 120s node Tests/Fixtures/PositronicRuntime/lifecycle.mjs | tee .testing/runtime-acp-smoke.log; GNOSTIC_PK_RUNTIME_BINARY="$$runtime_bin" timeout --signal=TERM --kill-after=5s 120s node Tests/Fixtures/PositronicRuntime/persistence.mjs | tee .testing/runtime-persistence-smoke.log; GNOSTIC_PK_RUNTIME_BINARY="$$runtime_bin" timeout --signal=TERM --kill-after=5s 120s node Tests/Fixtures/PositronicRuntime/history.mjs | tee .testing/runtime-history-smoke.log; GNOSTIC_PK_RUNTIME_BINARY="$$runtime_bin" timeout --signal=TERM --kill-after=5s 120s swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --skip-build --filter RuntimeACPSubprocessTests | tee .testing/runtime-acp-swift-tests.log; grep -Eq "Test run with [1-9][0-9]* tests" .testing/runtime-acp-swift-tests.log; GNOSTIC_ACP_AGENT_FIXTURE=/workspace/Tests/Fixtures/ACPAgent/agent.mjs timeout --signal=TERM --kill-after=5s 120s swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --skip-build --filter GnosticACPAscendantTests | tee .testing/acp-backend-smoke.log; grep -Eq "Test run with [1-9][0-9]* tests" .testing/acp-backend-smoke.log; GNOSTIC_ACP_BINARY="$$bin" GNOSTIC_ACP_OFFICIAL_CLIENT=/workspace/Tests/Fixtures/OfficialACPClient/lifecycle.mjs GNOSTIC_PI_ACP_CLIENT_FIXTURE=/workspace/Tests/Fixtures/PiACPClient/lifecycle.mjs timeout --signal=TERM --kill-after=5s 120s swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --skip-build --filter ACPSubprocessTests | tee .testing/acp-smoke.log; grep -Eq "Test run with [1-9][0-9]* tests" .testing/acp-smoke.log'

acp-backend-test: require-package require-build-configuration image
	@mkdir -p .testing
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash -o pipefail -c 'set -e; npm ci --prefix Tests/Fixtures/ACPAgent --cache .build/npm-cache; swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic; swift build $(SWIFT_LOCKED_ARGS) --build-tests; GNOSTIC_ACP_AGENT_FIXTURE=/workspace/Tests/Fixtures/ACPAgent/agent.mjs timeout --signal=TERM --kill-after=5s 120s swift test $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --skip-build --filter "$(ACP_TEST_FILTER)" | tee .testing/acp-backend-tests.log; grep -Eq "Test run with [1-9][0-9]* tests?" .testing/acp-backend-tests.log'

# Explicit operator action only. This live path is deliberately not a dependency of verify or CI.
ACP_LIVE_AGENT ?=
ACP_LIVE_TIMEOUT ?= 180
acp-live-smoke: build
	@test -n "$(ACP_LIVE_AGENT)" || { echo "Set ACP_LIVE_AGENT to opencode, codex, or claude-agent" >&2; exit 2; }
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash -o pipefail -c 'set -e; bin=$$(swift build $(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS) --product gnostic-acp-live-smoke --show-bin-path)/gnostic-acp-live-smoke; test -x "$$bin" || { echo "Could not locate live smoke executable at $$bin" >&2; exit 1; }; timeout --signal=TERM --kill-after=5s "$(ACP_LIVE_TIMEOUT)s" "$$bin" "$(ACP_LIVE_AGENT)"'

container-smoke: image
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh /workspace/Scripts/container-smoke.sh

# Long-running resource-bound run over the deterministic ACP fixture agent. It
# is not part of verify; run it deliberately and read the summary.
soak: require-package image
	@GNOSTIC_BUILD_REVISION="$$(git rev-parse HEAD)" SWIFT_FLAGS="$(SWIFT_LOCKED_ARGS) $(SWIFT_WARNING_ARGS)" $(CONTAINER_RUN_ENV) EXTRA_CONTAINER_ENV="$(EXTRA_CONTAINER_ENV) -e SOAK_DURATION_SECONDS -e SOAK_TURNS -e SOAK_TURN_INTERVAL_MS -e SOAK_SAMPLE_INTERVAL_SECONDS -e SOAK_MAX_RSS_KB -e SOAK_MAX_THREADS -e SOAK_TURN_TIMEOUT_SECONDS -e SOAK_BROKER_HOST -e SOAK_BROKER_PORT -e SOAK_NAMESPACE -e SOAK_ARTIFACT_ROOT" ./.devcontainer/run.sh /workspace/Scripts/soak.sh

macos-rlm-smoke: require-package
	@bash Scripts/macos-rlm-smoke.sh

# Runs on macOS only (CI job `macos-product`): release build, full Swift test
# suite against a local broker, and the filesystem Workspace release proof.
macos-product-proof: require-package
	@bash Scripts/macos-product-proof.sh

# Release-time SBOM for the SwiftPM dependency graph. Not part of verify: the
# output embeds a random serial number and creation timestamp, and SwiftPM
# warns that it omits build-time conditionals and does not cover the
# container's system packages. See README "Generate an SBOM".
sbom: require-package image
	@mkdir -p .testing/sbom
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash -o pipefail -c 'rm -rf .testing/sbom; mkdir -p .testing/sbom; swift package generate-sbom --cache-path /workspace/.swiftpm-cache --sbom-spec spdx --sbom-spec cyclonedx --sbom-output-dir .testing/sbom && ls -1 .testing/sbom'

verify: docs-check lint test

shell: image
	@$(CONTAINER_RUN_ENV) ./.devcontainer/run.sh bash

dev-up: build
	@$(DEV_STACK_ENV) ./Scripts/dev-stack.sh up

dev-status:
	@$(DEV_STACK_ENV) ./Scripts/dev-stack.sh status

dev-down:
	@$(DEV_STACK_ENV) ./Scripts/dev-stack.sh down

clean:
	@mkdir -p "$(BUILD_DIR)"
	@build_dir="$$(CDPATH= cd -- "$(BUILD_DIR)" && pwd -P)"; ./.devcontainer/lock.sh "$$build_dir" "$(BUILD_LOCK_TIMEOUT)" rm -rf -- "$$build_dir"
