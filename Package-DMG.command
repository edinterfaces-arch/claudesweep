#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "DMG packaging requires macOS 13+ with Swift 5.9+ Command Line Tools."
  exit 1
fi

# Always test and rebuild; never package a stale executable.
SWEEP_NO_REVEAL=1 bash "$PWD/Build.command"
app_dir="$PWD/dist/Claude Sweep.app"
/usr/bin/codesign --verify --strict --verbose=2 "$app_dir"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
architecture=$(/usr/bin/uname -m)
dmg_name="ClaudeSweep-${version}-${architecture}.dmg"
work_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/claudesweep-dmg.XXXXXX")
trap '/bin/rm -rf "$work_dir"' EXIT
/bin/mkdir "$work_dir/staging"
/usr/bin/ditto "$app_dir" "$work_dir/staging/Claude Sweep.app"
/bin/ln -s /Applications "$work_dir/staging/Applications"
/bin/cat > "$work_dir/staging/Read Me.txt" <<'README'
Claude Sweep — local build

Drag Claude Sweep.app to Applications, then eject this disk image.
This build targets the architecture shown in the DMG filename.

This is an independently developed prototype with an ad-hoc signature.
It is not Developer ID signed or notarized by Apple. Do not disable
Gatekeeper or SIP. For use on another Mac, sign and notarize a release
or build from the reviewed source on that Mac.

Review every cleanup selection. File cleanup moves selected items to
Trash; selected Keychain entries are permanently deleted after confirmation.
Local cleanup cannot erase server records or guarantee account unlinking.
README

echo "Creating compressed disk image…"
/usr/bin/hdiutil create -volname "Claude Sweep" -srcfolder "$work_dir/staging" \
  -format UDZO -fs HFS+ "$work_dir/$dmg_name"
/usr/bin/hdiutil verify "$work_dir/$dmg_name"
# Replace an earlier build only after the new image verifies successfully.
/bin/mv -f "$work_dir/$dmg_name" "$PWD/dist/$dmg_name"
(
  cd "$PWD/dist"
  /usr/bin/shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
)
echo "Created: $PWD/dist/$dmg_name"
echo "Checksum: $PWD/dist/$dmg_name.sha256"
if [[ "${SWEEP_NO_REVEAL:-0}" != "1" ]]; then
  /usr/bin/open -R "$PWD/dist/$dmg_name"
fi
