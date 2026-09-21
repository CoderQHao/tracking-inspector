#!/bin/bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
archive_dir="$repo_dir/dist/TrackingInspector.xcarchive"
app_dir="$repo_dir/dist/Tracking Inspector.app"
xcodebuild -project TrackingInspector.xcodeproj -scheme TrackingInspector \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$repo_dir/.build/xcode" -archivePath "$archive_dir" \
  CODE_SIGN_IDENTITY="${SIGNING_IDENTITY:--}" archive
rm -rf -- "$app_dir"
ditto "$archive_dir/Products/Applications/Tracking Inspector.app" "$app_dir"
test "$(lipo -archs "$app_dir/Contents/MacOS/TrackingInspector")" = arm64
codesign --verify --strict "$app_dir"
# Let macOS notice changed bundle resources when rebuilding at the same path.
touch "$app_dir"
ditto -c -k --keepParent "$app_dir" "$repo_dir/dist/Tracking-Inspector.zip"
echo "Built: $app_dir"
