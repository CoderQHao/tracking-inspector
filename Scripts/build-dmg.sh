#!/bin/bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
bash Scripts/build-app.sh
app_dir="$repo_dir/dist/Tracking Inspector.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid app version' >&2; exit 1; }
dmg_name="Tracking-Inspector-${version}-arm64.dmg"
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/tracking-inspector-dmg.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
ditto "$app_dir" "$staging_dir/Tracking Inspector.app"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -volname 'Tracking Inspector' -srcfolder "$staging_dir" -fs HFS+ -format UDZO -ov "$repo_dir/dist/$dmg_name"
hdiutil verify "$repo_dir/dist/$dmg_name"
(cd dist && shasum -a 256 "$dmg_name" Tracking-Inspector.zip > SHA256SUMS)
echo "Built: $repo_dir/dist/$dmg_name"
