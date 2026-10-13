#!/usr/bin/env bash
# rotate-sops.sh
# Rotates the pull secret for a single environment using SOPS encryption.
# The encrypted file is safe to commit to a public GitHub repo.
#
# Usage:
#   ./sops-approach/scripts/rotate-sops.sh <env> <path-to-new-pull-secret.json>
#   env: uat | pld | dr
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOPS_DIR="${ROOT_DIR}/sops-approach"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}WARN:${NC} $*"; }
error()   { echo -e "${RED}ERROR:${NC} $*"; exit 1; }
section() { echo ""; echo "────────────────────────────────────────"; echo "  $*"; echo "────────────────────────────────────────"; }

[[ $# -lt 2 ]] && { echo "Usage: $0 <env> <path-to-new-pull-secret.json>"; exit 1; }
ENV="$1"
NEW_SECRET_FILE="$(realpath "$2")"
VALID_ENVS=("uat" "pld" "dr")
VALID=false
for v in "${VALID_ENVS[@]}"; do [[ "$ENV" == "$v" ]] && VALID=true && break; done
[[ "$VALID" == "false" ]] && error "Unknown environment '$ENV'."
[[ ! -f "$NEW_SECRET_FILE" ]] && error "File not found: $NEW_SECRET_FILE"

command -v oc   &>/dev/null || error "oc not found"
command -v jq   &>/dev/null || error "jq not found"
command -v sops &>/dev/null || error "sops not found — run bootstrap-sops.sh first"
command -v age  &>/dev/null || error "age not found — run bootstrap-sops.sh first"

info "Environment : $ENV"
info "Cluster     : $(oc whoami --show-server)"
info "New secret  : $NEW_SECRET_FILE"

# ── Step 1: Backup ────────────────────────────────────────────────────────────
section "Step 1/4 — Backup current pull secret"
BACKUP_DIR="${ROOT_DIR}/backups"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/pull-secret-${ENV}-${TIMESTAMP}.json"

oc get secret/pull-secret -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' > "$BACKUP_FILE"
jq . "$BACKUP_FILE" > "${BACKUP_FILE}.tmp" && mv "${BACKUP_FILE}.tmp" "$BACKUP_FILE"
info "Backup: $BACKUP_FILE"
info "Current registries:"
jq '.auths | keys' "$BACKUP_FILE"

# ── Step 2: Validate + merge ──────────────────────────────────────────────────
section "Step 2/4 — Validate + merge"
jq -e '.auths' "$NEW_SECRET_FILE" > /dev/null 2>&1 || error "Not valid pull secret JSON"

info "New secret registries:"
jq '.auths | keys' "$NEW_SECRET_FILE"

PULLER=""
command -v podman &>/dev/null && PULLER="podman"
command -v docker &>/dev/null && [[ -z "$PULLER" ]] && PULLER="docker"
if [[ -n "$PULLER" ]]; then
  info "Testing image pull..."
  $PULLER pull --authfile "$NEW_SECRET_FILE" registry.redhat.io/ubi8/ubi:latest \
    && info "Pull succeeded." || error "Pull FAILED — check the new pull secret."
fi

MERGED_FILE=$(mktemp /tmp/merged-XXXXXX.json)
trap 'rm -f "$MERGED_FILE"' EXIT

jq -s '{auths: (.[0].auths + .[1].auths)}' \
  "$NEW_SECRET_FILE" "$BACKUP_FILE" > "$MERGED_FILE"

info "Merged registries:"
jq '.auths | keys' "$MERGED_FILE"

# ── Step 3: Write + SOPS-encrypt the ConfigMap ───────────────────────────────
section "Step 3/4 — Encrypt ConfigMap with SOPS + age"

OVERLAY_DIR="${SOPS_DIR}/gitops/overlays/${ENV}"
ENC_FILE="${OVERLAY_DIR}/pull-secret-cm.enc.yaml"
PLAIN_FILE=$(mktemp /tmp/pull-secret-cm-plain-XXXXXX.yaml)
trap 'rm -f "$MERGED_FILE" "$PLAIN_FILE"' EXIT

# base64-encode merged secret
B64=$(base64 -w 0 < "$MERGED_FILE")

# Write plain ConfigMap YAML
cat > "$PLAIN_FILE" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: pull-secret-data
  namespace: openshift-config
  labels:
    environment: ${ENV}
    rotation-timestamp: "${TIMESTAMP}"
binaryData:
  .dockerconfigjson: ${B64}
EOF

# Encrypt with SOPS using the .sops.yaml config
info "Encrypting with SOPS..."
SOPS_CONFIG="${SOPS_DIR}/.sops.yaml"
sops --config "$SOPS_CONFIG" --encrypt "$PLAIN_FILE" > "$ENC_FILE"

info "Encrypted ConfigMap written: $ENC_FILE"

# ── Step 4: Update Job timestamp ─────────────────────────────────────────────
section "Step 4/4 — Update Job timestamp"
JOB_FILE="${SOPS_DIR}/gitops/base/rotation-job.yaml"
sed -i "s/pull-secret-rotation-[0-9]*/pull-secret-rotation-${TIMESTAMP}/" "$JOB_FILE" \
  || sed -i "s/pull-secret-rotation-TIMESTAMP/pull-secret-rotation-${TIMESTAMP}/" "$JOB_FILE"
info "Job name updated: pull-secret-rotation-${TIMESTAMP}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✓ Ready to deploy rotation for ${ENV}${NC}"
echo ""
echo "  Run these git commands:"
echo ""
echo "    git add sops-approach/gitops/overlays/${ENV}/pull-secret-cm.enc.yaml"
echo "    git add sops-approach/gitops/base/rotation-job.yaml"
echo "    git commit -m \"chore: rotate pull secret for ${ENV} [$(date +%Y-%m-%d)]\""
echo "    git push"
echo ""
echo "  Then monitor:"
echo "    oc get job -n openshift-config | grep pull-secret-rotation"
echo "    oc logs -n openshift-config job/pull-secret-rotation-${TIMESTAMP} -f"
echo "    oc get secret pull-secret -n openshift-config \\"
echo "      --template='{{index .data \".dockerconfigjson\" | base64decode}}' | jq '.auths | keys'"
