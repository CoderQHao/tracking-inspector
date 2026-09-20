#!/bin/bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
app_dir="$repo_dir/dist/Tracking Inspector.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
if [[ "${1:-}" == "--universal" ]]; then
  swift build --build-system native -c release --product TrackingInspector --arch arm64
  swift build --build-system native -c release --product TrackingInspector --arch x86_64
  lipo -create .build/arm64-apple-macosx/release/TrackingInspector .build/x86_64-apple-macosx/release/TrackingInspector -output "$app_dir/Contents/MacOS/TrackingInspector"
else
  swift build --build-system native -c release --product TrackingInspector
  binary_dir=$(swift build --build-system native -c release --show-bin-path)
  cp "$binary_dir/TrackingInspector" "$app_dir/Contents/MacOS/TrackingInspector"
fi
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
bash Scripts/build-icon.sh "$app_dir/Contents/Resources/AppIcon.icns"
ditto Sources/TrackingInspector/Web "$app_dir/Contents/Resources/Web"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$app_dir"
codesign --verify --strict "$app_dir"
# Let macOS notice changed bundle resources when rebuilding at the same path.
touch "$app_dir"
ditto -c -k --keepParent "$app_dir" "$repo_dir/dist/Tracking-Inspector.zip"
echo "Built: $app_dir"
