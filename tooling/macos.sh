#!/usr/bin/env bash
set -euo pipefail

steady_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
steady_package="$steady_root/apps/focus/macos"
steady_action="${1:-test}"
if [[ $# -gt 0 ]]; then shift; fi

steady_expected="${STEADY_SWIFT_VERSION:-6.2.3}"
steady_version="$(xcrun swift --version)"
if [[ "$steady_version" != *"Apple Swift version $steady_expected "* ]]; then
  printf 'Expected Apple Swift %s from the selected developer tools.\n' "$steady_expected" >&2
  printf '%s\n' "$steady_version" >&2
  exit 1
fi

build_app() {
  xcrun swift build --package-path "$steady_package" --product Steady
  steady_bin="$(xcrun swift build --package-path "$steady_package" --show-bin-path)"
  steady_app="$steady_package/.build/Steady.app"
  mkdir -p "$steady_app/Contents/MacOS"
  cp "$steady_bin/Steady" "$steady_app/Contents/MacOS/Steady"
  cp "$steady_package/Support/Info.plist" "$steady_app/Contents/Info.plist"
  codesign --force --sign - "$steady_app"
  printf 'App: %s\n' "$steady_app"
}

case "$steady_action" in
  test)
    steady_flags=(--disable-xctest --enable-swift-testing)
    steady_developer="$(xcode-select -p)"
    steady_frameworks="$steady_developer/Library/Developer/Frameworks"
    if [[ -d "$steady_frameworks/Testing.framework" ]]; then
      steady_flags+=(-Xswiftc -F -Xswiftc "$steady_frameworks")
      steady_flags+=(-Xlinker "-F$steady_frameworks" -Xlinker -rpath -Xlinker "$steady_frameworks")
      # CLT 6.2 ships the Foundation overlay as a binary without its module.
      # These tests need no overlay conveniences, only the Testing module itself.
      if [[ ! -e "$steady_frameworks/_Testing_Foundation.framework/Modules" ]]; then
        steady_flags+=(-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
      fi
      steady_swiftc="$(xcrun --find swiftc)"
      steady_macros="$(dirname "$steady_swiftc")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
      if [[ -f "$steady_macros" ]]; then
        steady_flags+=(-Xswiftc -load-plugin-library -Xswiftc "$steady_macros")
      fi
    fi
    exec xcrun swift test --package-path "$steady_package" "${steady_flags[@]}" "$@"
    ;;
  check)
    exec xcrun swift build --package-path "$steady_package" -Xswiftc -warnings-as-errors "$@"
    ;;
  build)
    build_app
    ;;
  run)
    build_app
    exec "$steady_app/Contents/MacOS/Steady" "$@"
    ;;
  *)
    printf 'Unknown action: %s\n' "$steady_action" >&2
    exit 2
    ;;
esac
