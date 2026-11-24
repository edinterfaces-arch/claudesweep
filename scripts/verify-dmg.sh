#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" || "$#" != "1" ]]; then
  echo "Usage on macOS: bash scripts/verify-dmg.sh path/to/ClaudeSweep.dmg"
  exit 1
fi

work_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/claudesweep-verify.XXXXXX")
mounted=0
app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ "$mounted" == "1" ]]; then
    /usr/bin/hdiutil detach "$work_dir/mount" || true
  fi
  /bin/rm -rf "$work_dir"
}
trap cleanup EXIT

/bin/mkdir "$work_dir/mount" "$work_dir/install"
/usr/bin/hdiutil attach "$1" -readonly -nobrowse -mountpoint "$work_dir/mount"
mounted=1
test "$(/usr/bin/readlink "$work_dir/mount/Applications")" = "/Applications"
/usr/bin/ditto "$work_dir/mount/Claude Sweep.app" "$work_dir/install/Claude Sweep.app"
app_dir="$work_dir/install/Claude Sweep.app"
/usr/bin/codesign --verify --strict --verbose=2 "$app_dir"
test -x "$app_dir/Contents/MacOS/ClaudeSweep"
echo "Executable architectures: $(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/ClaudeSweep")"

# Only launch the UI. No scan, cleanup or Keychain operation is requested.
"$app_dir/Contents/MacOS/ClaudeSweep" > "$work_dir/launch.log" 2>&1 &
app_pid=$!
sleep 5
if ! kill -0 "$app_pid" 2>/dev/null; then
  /bin/cat "$work_dir/launch.log"
  echo "The application exited unexpectedly during the launch check."
  exit 1
fi
echo "PASS: DMG mounted, app copied, signature verified, process remained running for 5 seconds."
