#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_PATH="${MAC_REMOTE_DIST_DIR:-$PROJECT_ROOT/dist}/Mac Remote.app"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
BUILD_OPTIONS=(--package-path "$PROJECT_ROOT" --configuration "$CONFIGURATION" --disable-sandbox
  --cache-path "$PROJECT_ROOT/.build/cache" --config-path "$PROJECT_ROOT/.build/config"
  --security-path "$PROJECT_ROOT/.build/security"
  -Xswiftc -module-cache-path -Xswiftc "$PROJECT_ROOT/.build/ModuleCache")

if [[ "${1:-}" == "--universal" ]]; then
  BUILD_ARCHITECTURES=(arm64 x86_64)
elif [[ -n "${1:-}" ]]; then
  echo "用法: ./Scripts/build.sh [--universal]" >&2
  exit 1
else
  BUILD_ARCHITECTURES=("$(uname -m)")
fi

BINARY_PATHS=()
RESOURCE_BUNDLE=""
for build_arch in "${BUILD_ARCHITECTURES[@]}"; do
  # Separate SwiftPM builds keep the same resource layout as single-architecture builds.
  swift build "${BUILD_OPTIONS[@]}" --arch "$build_arch"
  BINARY_DIR="$(swift build "${BUILD_OPTIONS[@]}" --arch "$build_arch" --show-bin-path)"
  BINARY_PATHS+=("$BINARY_DIR/MacRemote")
  if [[ -z "$RESOURCE_BUNDLE" ]]; then
    RESOURCE_BUNDLE="$BINARY_DIR/MacRemote_MacRemote.bundle"
  fi
done

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
if [[ ${#BINARY_PATHS[@]} -gt 1 ]]; then
  lipo -create "${BINARY_PATHS[@]}" -output "$APP_PATH/Contents/MacOS/MacRemote"
else
  cp "${BINARY_PATHS[0]}" "$APP_PATH/Contents/MacOS/MacRemote"
fi
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
# Replace generated resources so stale layouts cannot survive a later rebuild.
if [[ -d "$APP_PATH/Contents/Resources/MacRemote_MacRemote.bundle" ]]; then
  rm -rf "$APP_PATH/Contents/Resources/MacRemote_MacRemote.bundle"
fi
cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"

CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache" swift "$PROJECT_ROOT/Scripts/make-icon.swift" "$APP_PATH/Contents/Resources/AppIcon.icns"
python3 "$PROJECT_ROOT/Scripts/sign-app.py" "$APP_PATH"
echo "已构建：$APP_PATH"
