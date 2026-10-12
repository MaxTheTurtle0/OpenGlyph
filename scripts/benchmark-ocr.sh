#!/usr/bin/env bash
set -euo pipefail

# No package target is needed: compile the developer tool with a chosen Core source snapshot.
# CORE_SOURCE_DIR=/tmp/baseline-Core BENCHMARK_BINARY=/tmp/ocr-baseline \
#   scripts/benchmark-ocr.sh --build-only
# BENCHMARK_BINARY=/tmp/ocr-baseline scripts/benchmark-ocr.sh --no-build \
#   generate --fixtures-dir /tmp/ocr-fixtures
# BENCHMARK_BINARY=/tmp/ocr-baseline scripts/benchmark-ocr.sh --no-build \
#   run --fixtures-dir /tmp/ocr-fixtures --label baseline --idle-seconds 30 --output /tmp/baseline.json
# Compile a candidate to a separate BENCHMARK_BINARY, then run that same fixture directory.
# --start-delay-seconds 20 leaves time to attach Instruments before recognition starts.
# --execution-context worker is the default, matching the app's Task.detached recognition.
# --execution-context main selects the original main-thread benchmark for comparison.
# Background-processing experiments use an alternate Core source copy; production is the default.

benchmark_project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
benchmark_core_dir="${CORE_SOURCE_DIR:-$benchmark_project_root/Sources/OpenGlyphCore}"
benchmark_binary="${BENCHMARK_BINARY:-${TMPDIR:-/tmp}/openglyph-ocr-benchmark}"
benchmark_build=true
benchmark_build_only=false
if [[ "${1:-}" == "--no-build" ]]; then
  benchmark_build=false
  shift
elif [[ "${1:-}" == "--build-only" ]]; then
  benchmark_build_only=true
  shift
fi

if $benchmark_build; then
  shopt -s nullglob
  benchmark_core_sources=("$benchmark_core_dir"/*.swift)
  if [[ ${#benchmark_core_sources[@]} -eq 0 ]]; then
    printf '{"error":"core_source_directory_has_no_swift_files"}\n' >&2
    exit 1
  fi
  mkdir -p -- "$(dirname -- "$benchmark_binary")"
  # Match the app's macOS 14 deployment target rather than the host OS default.
  xcrun swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    "$benchmark_project_root/tools/OCRBenchmark.swift" "${benchmark_core_sources[@]}" \
    -o "$benchmark_binary"
fi

if $benchmark_build_only; then
  printf '{"binaryBuilt":true}\n'
  exit 0
fi
if [[ ! -x "$benchmark_binary" ]]; then
  printf '{"error":"benchmark_binary_is_missing"}\n' >&2
  exit 1
fi
exec "$benchmark_binary" "$@"
