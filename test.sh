#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_BUILD="$ROOT/build/tests"
TEST_BINARY="$TEST_BUILD/AudioRenderKernelTests"

mkdir -p "$TEST_BUILD"

echo "==> Building DSP regression tests"
swiftc -O \
  -o "$TEST_BINARY" \
  "$ROOT/Sources/AudioRenderKernel.swift" \
  "$ROOT/Sources/CoreAudioHelpers.swift" \
  "$ROOT/Tests/AudioRenderKernelTests.swift" \
  -framework AudioToolbox \
  -framework Accelerate \
  -target "arm64-apple-macos14.2"

echo "==> Running DSP regression tests"
"$TEST_BINARY"
