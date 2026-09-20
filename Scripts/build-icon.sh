#!/bin/bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
output_path="${1:-$repo_dir/dist/AppIcon.icns}"
icon_dir=$(mktemp -d "${TMPDIR:-/tmp}/tracking-inspector-icon.XXXXXX")
trap 'rm -rf -- "$icon_dir"' EXIT
iconset_dir="$icon_dir/AppIcon.iconset"
mkdir -p "$iconset_dir" "$(dirname -- "$output_path")"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$repo_dir/Resources/AppIcon.png" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$repo_dir/Resources/AppIcon.png" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$output_path"
