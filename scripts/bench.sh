#!/bin/zsh
# Benchmarks on frames recorded from a capture card (open build/MacFrameGen.app --args --autostart --record <dir> 90).
#   scripts/bench.sh framegen   <recordDir> [outDir]   quality/speed of Apple ML vs the GPU shader
#   scripts/bench.sh resolution <recordDir> [clean]    render-resolution detector checks
# Without arguments it only compiles both (used by CI to keep them building).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/bench
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  Sources/Interpolator.swift Sources/MetalInterpolator.swift Tests/Benchmarks/FrameGenBench/main.swift -o build/bench/framegen
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  Sources/ResolutionDetector.swift Tests/Benchmarks/ResolutionBench/main.swift -o build/bench/resolution
if (( $# > 0 )); then
  tool=$1; shift
  ./build/bench/$tool "$@"
fi
