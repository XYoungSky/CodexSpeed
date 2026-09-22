#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cache .build/clang
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang"
swift run --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" CoreChecks
