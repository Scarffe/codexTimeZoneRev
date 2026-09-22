#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-build}"
cd "$project_root/flutter_app"
flutter pub get
export CARGO_TARGET_DIR="$project_root/environment/flutter-cargo-target"
if [[ "$action" == test ]]; then
  cargo test --manifest-path "$project_root/native/launcher_core/Cargo.toml"
  flutter analyze
  flutter test
  exit 0
fi
if [[ "$action" == preview ]]; then
  flutter run -d macos --dart-define=UI_PREVIEW=true
  exit 0
fi
cargo build --release --manifest-path "$project_root/native/launcher_core/Cargo.toml"
export CODEX_TZ_NATIVE_LIBRARY="$CARGO_TARGET_DIR/release/libcodex_timezone_core.dylib"
if [[ "$action" == run ]]; then
  flutter run -d macos
elif [[ "$action" == build ]]; then
  flutter build macos --release
  app="$project_root/flutter_app/build/macos/Build/Products/Release/Codex 时区启动器.app"
  cp "$CODEX_TZ_NATIVE_LIBRARY" "$app/Contents/Frameworks/"
  codesign --force --sign - "$app/Contents/Frameworks/libcodex_timezone_core.dylib"
  codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$app"
  codesign --verify --deep --strict "$app"
  mkdir -p "$project_root/environment/artifacts"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$project_root/environment/artifacts/CodexTimeZone-Flutter-macos-$(uname -m).zip"
  printf 'Ad-hoc signed local build: %s\nDistribution requires Developer ID signing and notarization.\n' "$app"
else
  printf 'Unknown action: %s\n' "$action" >&2
  exit 1
fi
