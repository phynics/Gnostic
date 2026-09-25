#!/usr/bin/env bash

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "macOS RLM smoke requires macOS" >&2
    exit 1
fi

command -v brew >/dev/null
command -v guile >/dev/null
guile --version | grep -F "GNU Guile) 3.0."

mkdir -p .testing
swift build --target GnosticACPAscendant --disable-automatic-resolution --build-system native \
    --quiet -Xswiftc -warnings-as-errors \
    | tee .testing/macos-acp-target-build.log

prefix=$(brew --prefix)
PREFIX="$prefix" bash Scripts/install-rlm-limit-exec.sh
PREFIX="$prefix" bash Scripts/build-chibi-rlm.sh

launcher="$prefix/bin/gnostic-rlm-limit-exec"
"$launcher" --cpu=10 -- /bin/sh -c 'test "$(ulimit -t)" -eq 10'
if "$launcher" --cpu=10 --as=268435456 -- /usr/bin/true; then
    echo "Darwin launcher must reject unsupported address-space limits" >&2
    exit 1
fi

export GNOSTIC_GUILE="$(command -v guile)"
export GNOSTIC_CHIBI="$prefix/bin/chibi-scheme"

mac_package=$(mktemp -d)
trap 'rm -rf "$mac_package"' EXIT INT TERM
mkdir -p "$mac_package/Sources" "$mac_package/Tests/Fixtures"
cp -R Sources/GnosticRLM \
    Sources/GnosticRLMProcessWorker \
    Sources/GnosticRLMGuile \
    Sources/GnosticRLMChibi \
    "$mac_package/Sources/"
cp -R Tests/GnosticRLMGuileTests \
    Tests/GnosticRLMChibiTests \
    Tests/GnosticRLMWorkerParityTests \
    "$mac_package/Tests/"
cp -R Tests/Fixtures/RLMWorkerStubs "$mac_package/Tests/Fixtures/"

cat > "$mac_package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "GnosticRLM",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "GnosticRLM"),
        .target(name: "GnosticRLMProcessWorker", dependencies: ["GnosticRLM"]),
        .target(
            name: "GnosticRLMGuile",
            dependencies: ["GnosticRLM", "GnosticRLMProcessWorker"],
            resources: [.copy("Resources/worker.scm")]
        ),
        .target(
            name: "GnosticRLMChibi",
            dependencies: ["GnosticRLM", "GnosticRLMProcessWorker"],
            resources: [.copy("Resources/worker.scm")]
        ),
        .testTarget(name: "GnosticRLMGuileTests", dependencies: ["GnosticRLM", "GnosticRLMGuile"]),
        .testTarget(name: "GnosticRLMChibiTests", dependencies: ["GnosticRLM", "GnosticRLMChibi"]),
        .testTarget(
            name: "GnosticRLMWorkerParityTests",
            dependencies: ["GnosticRLM", "GnosticRLMGuile", "GnosticRLMChibi"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
SWIFT

: > .testing/macos-rlm-smoke.log
evidence_dir=.testing/macos-rlm-smoke
rm -rf "$evidence_dir"
mkdir -p "$evidence_dir"
for test_filter in \
    RLMGuileWorkerSessionTests \
    RLMGuileSandboxDenialTests \
    RLMGuileProcessSignalsTests \
    RLMGuileOperationTests \
    RLMChibiWorkerSessionTests \
    RLMChibiSandboxDenialTests \
    RLMChibiProcessSignalsTests \
    RLMChibiOperationTests \
    RLMWorkerWireParityTests; do
    suite_log="$evidence_dir/${test_filter}.log"
    if ! swift test --package-path "$mac_package" --disable-automatic-resolution --build-system native \
        --quiet -Xswiftc -warnings-as-errors --filter "$test_filter" \
        --xunit-output "$evidence_dir/${test_filter}-swift-testing.xml" \
        >"$suite_log" 2>&1; then
        tee -a .testing/macos-rlm-smoke.log <"$suite_log"
        exit 1
    fi
    tee -a .testing/macos-rlm-smoke.log <"$suite_log"
    grep -Eq 'Test run with [1-9][0-9]* tests' "$suite_log"
done
