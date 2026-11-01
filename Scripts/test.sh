#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
# XCTest is bundled with Xcode, but not standalone Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config \
  --security-path .build/security -Xswiftc -module-cache-path -Xswiftc .build/ModuleCache
node --check Sources/MacRemote/Web/app.js
if [[ "${1:-}" == "--web" ]]; then node Tests/Web/browser.mjs; fi
