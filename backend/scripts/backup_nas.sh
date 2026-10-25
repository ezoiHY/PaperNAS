#!/usr/bin/env bash
# Consistent offline backup for the dedicated NAS deployment. No deletion/rotation.
set -euo pipefail
base="${PAPERNAS_DEPLOY_ROOT:-$HOME/paper-nas-v2}"
destination="$base/backups/v2-$(date +%Y%m%dT%H%M%S)"
umask 077
mkdir "$destination"
active=()
for unit in papernas-v2-api papernas-v2-worker papernas-v2-parse; do
  if systemctl --user is-active --quiet "$unit"; then active+=("$unit"); fi
done
resume() {
  if [ "${#active[@]}" -gt 0 ]; then systemctl --user start "${active[@]}"; fi
}
trap resume EXIT
if [ "${#active[@]}" -gt 0 ]; then systemctl --user stop "${active[@]}"; fi
"$base/runtime/postgres/bin/pg_dump" -h "$base/run" -p 55439 -d papernas_v2 -Fc -f "$destination/database.dump"
tar -C "$base" -cf "$destination/state.tar" state
cp "$base/service.env" "$destination/service.env"
cp "$base/current/constraints-linux-x86_64.txt" "$destination/constraints-linux-x86_64.txt"
readlink "$base/current" > "$destination/release.txt"
(
  cd "$destination"
  sha256sum database.dump state.tar > SHA256SUMS
)
printf 'Verified command completion; backup saved to %s\n' "$destination"
