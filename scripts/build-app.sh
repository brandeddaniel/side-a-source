#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-release}"
architecture="${2:-$(uname -m)}"
if [[ "$mode" != "release" && "$mode" != "debug" ]]; then
  echo "Usage: $0 [release|debug] [arm64|x86_64]" >&2
  exit 2
fi
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture" >&2; exit 2 ;; esac
triple="$architecture-apple-macosx14.0"
cp bridge/*.py Sources/SideA/Resources/
swift build -c "$mode" --triple "$triple" --scratch-path ".build/package-$architecture"
bin_dir="$(swift build -c "$mode" --triple "$triple" --scratch-path ".build/package-$architecture" --show-bin-path)"
app_path="$PWD/dist/$architecture/Side A.app"
if [[ $# -lt 2 ]]; then app_path="$PWD/dist/Side A.app"; fi
if [[ -d "$app_path" ]]; then rm -rf "$app_path"; fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/SideA" "$app_path/Contents/MacOS/SideA"
# AppResources resolves packaged resources inside Contents/Resources.
cp -R "$bin_dir/SideA_SideA.bundle" "$app_path/Contents/Resources/SideA_SideA.bundle"
cp scripts/Info.plist "$app_path/Contents/Info.plist"
if [[ -f design/SideA.icns ]]; then cp design/SideA.icns "$app_path/Contents/Resources/SideA.icns"; fi
codesign --force --sign - "$app_path"
echo "$app_path"
