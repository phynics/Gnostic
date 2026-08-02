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

.PHONY: help image require-package resolve worktree-bootstrap build test container-smoke verify shell clean

help:
	@echo "Targets: image resolve worktree-bootstrap build test container-smoke verify shell clean"

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
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh swift build $(SWIFT_LOCKED_ARGS)

test: require-package image
	@mkdir -p .testing
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash -o pipefail -c 'pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d; swift test $(SWIFT_LOCKED_ARGS) | tee .testing/swift-test.log && rg -q "Test run with [1-9][0-9]* tests passed" .testing/swift-test.log'

container-smoke: image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh swift --version

verify: build test

shell: image
	@BUILD_DIR="$(BUILD_DIR)" BUILD_LOCK="$(BUILD_LOCK)" SPM_CACHE_DIR="$(SPM_CACHE_DIR)" EXTRA_CONTAINER_MOUNTS="$(EXTRA_CONTAINER_MOUNTS)" IMAGE="$(IMAGE)" CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" ./.devcontainer/run.sh bash

clean:
	@rm -rf "$(BUILD_CACHE_ROOT)" .swiftpm-cache .testing
