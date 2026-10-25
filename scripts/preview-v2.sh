#!/bin/bash
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd)
connection_file=${1:-"$task_root/backend/.runtime/preview-connection.json"}
test -f "$connection_file"
test -d "$task_root/dist/Paper NAS.app"
preview_app="$task_root/dist/Paper NAS Preview.app"
ditto "$task_root/dist/Paper NAS.app" "$preview_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.harryhan.paper-nas.preview' "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Paper NAS Preview' "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Paper NAS Preview' "$preview_app/Contents/Info.plist"
codesign --force --sign - --options runtime "$preview_app"
# Keep generated preview credentials outside Documents so this test does not
# request access to the user's Documents folder. No Keychain entry is changed.
preview_connection=$(mktemp "${TMPDIR:-/tmp/}papernas-v2-preview.XXXXXX")
cp "$connection_file" "$preview_connection"
chmod 600 "$preview_connection"
open "$preview_app" --args --preview-connection-file "$preview_connection"
