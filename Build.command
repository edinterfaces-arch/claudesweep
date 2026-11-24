#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Claude Sweep must be built on macOS 13 or newer."
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Install Apple's Command Line Tools with: xcode-select --install"
  echo "Then run Build.command again. Xcode 15 / Swift 5.9 or newer is required."
  exit 1
fi

echo "Running tests (native cleanup tests require CLAUDESWEEP_RUN_INTEGRATION_TESTS=1)…"
swift test
echo "Building the native app…"
swift build -c release --product ClaudeSweep
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/dist/Claude Sweep.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/ClaudeSweep" "$app_dir/Contents/MacOS/ClaudeSweep"
cp "$PWD/Support/Info.plist" "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
echo "Built: $app_dir"
echo "This is a locally built, ad-hoc signed app, not an Apple-notarized release."
if [[ "${SWEEP_NO_REVEAL:-0}" != "1" ]]; then
  open -R "$app_dir"
fi
