#!/bin/zsh
# Builds and runs the self-tests (no capture card needed). GPU checks are skipped without Metal.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  Sources/Interpolator.swift Sources/MetalInterpolator.swift Sources/ResolutionDetector.swift \
  Tests/SelfTest/main.swift -o build/tests/selftest
./build/tests/selftest
