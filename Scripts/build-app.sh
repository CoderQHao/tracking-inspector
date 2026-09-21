#!/bin/bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
app_dir="$repo_dir/dist/Tracking Inspector.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swift build --build-system native -c release --product TrackingInspector --arch arm64
binary_dir=$(swift build --build-system native -c release --arch arm64 --show-bin-path)
cp "$binary_dir/TrackingInspector" "$app_dir/Contents/MacOS/TrackingInspector"
test "$(lipo -archs "$app_dir/Contents/MacOS/TrackingInspector")" = arm64
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
bash Scripts/build-icon.sh "$app_dir/Contents/Resources/AppIcon.icns"
ditto Sources/TrackingInspector/Web "$app_dir/Contents/Resources/Web"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$app_dir"
codesign --verify --strict "$app_dir"
# Let macOS notice changed bundle resources when rebuilding at the same path.
touch "$app_dir"
ditto -c -k --keepParent "$app_dir" "$repo_dir/dist/Tracking-Inspector.zip"
echo "Built: $app_dir"
