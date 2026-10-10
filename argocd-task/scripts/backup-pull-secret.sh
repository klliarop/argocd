#!/usr/bin/env bash
# backup-pull-secret.sh
# Backs up the current global pull secret from the connected cluster.
# Usage: ./scripts/backup-pull-secret.sh
# Output: backups/pull-secret-<timestamp>.json
set -euo pipefail

BACKUP_DIR="$(cd "$(dirname "$0")/.." && pwd)/backups"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
OUTFILE="$BACKUP_DIR/pull-secret-${TIMESTAMP}.json"

echo "==> Current cluster context: $(oc config current-context)"
echo "==> Backing up pull secret from openshift-config namespace..."

oc get secret/pull-secret \
  -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' \
  > "$OUTFILE"

# Pretty-print if jq is available
if command -v jq &>/dev/null; then
  jq . "$OUTFILE" > "${OUTFILE}.tmp" && mv "${OUTFILE}.tmp" "$OUTFILE"
  echo "==> Registries in current secret:"
  jq '.auths | keys' "$OUTFILE"
fi

echo ""
echo "✓ Backup saved to: $OUTFILE"
echo "  Keep this file safe — you will need it for rollback."
