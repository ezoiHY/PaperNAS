#!/bin/bash
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd)
configuration=${1:-release}
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
minimum_os=$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$task_root/macOS/Info.plist")
cd "$task_root/macOS"
# Swift Build can stamp the deployment target as the SDK version. AppKit then
# applies legacy window geometry. Record the SDK actually used for this build.
build_args=(-c "$configuration" --sdk "$sdk_path"
  -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_os" -Xlinker "$sdk_version")
swift build "${build_args[@]}"
binary_dir=$(swift build "${build_args[@]}" --show-bin-path)
linked_sdk=$(xcrun vtool -show-build "$binary_dir/PaperNAS" | awk '$1 == "sdk" {print $2; exit}')
if [ "$linked_sdk" != "$sdk_version" ]; then
  echo "SDK version mismatch: linked $linked_sdk, expected $sdk_version" >&2
  exit 1
fi
app_dir="$task_root/dist/Paper NAS.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/PaperNAS" "$app_dir/Contents/MacOS/PaperNAS"
cp "$task_root/macOS/Info.plist" "$app_dir/Contents/Info.plist"
# Optional, exact HTTP exception for a trusted private-network deployment.
# HTTPS and local loopback work without this setting. Never bake an operator's
# private address into the public source tree.
if [ -n "${PAPERNAS_HTTP_HOST:-}" ]; then
  python3 "$task_root/scripts/configure-app.py" "$app_dir/Contents/Info.plist" "$PAPERNAS_HTTP_HOST"
fi
ditto "$binary_dir/PaperNAS_PaperNAS.bundle" "$app_dir/Contents/Resources/PaperNAS_PaperNAS.bundle"
cp "$task_root/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$task_root/THIRD-PARTY-NOTICES.md" "$app_dir/Contents/Resources/THIRD-PARTY-NOTICES.md"
swift "$task_root/scripts/make-icon.swift" "$task_root/dist/AppIcon.iconset"
iconutil -c icns "$task_root/dist/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign "${PAPERNAS_SIGN_IDENTITY:--}" --options runtime "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
