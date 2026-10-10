#!/usr/bin/env bash
# rotate-pull-secret.sh
# All-in-one pull secret rotation for a single environment.
# Run this every time you need to rotate the pull secret.
#
# What it does (in order):
#   1. Backs up the current pull secret from the cluster
#   2. Validates the new pull secret (real image pull test)
#   3. Merges the new secret with existing registry credentials (preserves cp.icr.io, us.icr.io, etc.)
#   4. Seals the merged secret for the target environment using kubeseal
#   5. Writes gitops/overlays/<env>/sealed-secret.yaml (safe to commit)
#   6. Prints the exact git commands to run
#
# Usage:
#   ./scripts/rotate-pull-secret.sh <env> <path-to-new-pull-secret.json>
#
#   <env>                       : uat | pld | dr
#   <path-to-new-pull-secret.json>: downloaded from https://console.redhat.com/openshift/downloads
#
# Prerequisites:
#   - oc logged in to the TARGET cluster for <env>  (oc login <api-url>)
#   - kubeseal CLI on PATH  (run bootstrap-cluster.sh once if not installed)
#   - Sealed Secrets controller running on the cluster  (run bootstrap-cluster.sh once)
#   - jq on PATH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}WARN:${NC} $*"; }
error()   { echo -e "${RED}ERROR:${NC} $*"; exit 1; }
section() { echo ""; echo "────────────────────────────────────────"; echo "  $*"; echo "────────────────────────────────────────"; }

# ── Argument check ────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <env> <path-to-new-pull-secret.json>"
  echo "  env: uat | pld | dr"
  echo ""
  echo "  Download the new pull secret from:"
  echo "  https://console.redhat.com/openshift/downloads"
  exit 1
fi

ENV="$1"
NEW_SECRET_FILE="$(realpath "$2")"

VALID_ENVS=("uat" "pld" "dr")
VALID=false
for v in "${VALID_ENVS[@]}"; do [[ "$ENV" == "$v" ]] && VALID=true && break; done
[[ "$VALID" == "false" ]] && error "Unknown environment '$ENV'. Must be one of: uat, pld, dr"
[[ ! -f "$NEW_SECRET_FILE" ]] && error "New pull secret file not found: $NEW_SECRET_FILE"

# ── Tool checks ───────────────────────────────────────────────────────────────
command -v oc       &>/dev/null || error "oc not found on PATH"
command -v jq       &>/dev/null || error "jq not found. Install: https://stedolan.github.io/jq/download/"
command -v kubeseal &>/dev/null || error "kubeseal not found. Run: ./scripts/bootstrap-cluster.sh ${ENV}"

CLUSTER_API=$(oc whoami --show-server)
info "Environment : $ENV"
info "Cluster     : $CLUSTER_API"
info "Logged in as: $(oc whoami)"
info "New secret  : $NEW_SECRET_FILE"
echo ""

# ── Step 1: Backup current pull secret ───────────────────────────────────────
section "Step 1/4 — Backup current pull secret"

BACKUP_DIR="${ROOT_DIR}/backups"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/pull-secret-${ENV}-${TIMESTAMP}.json"

oc get secret/pull-secret \
  -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' \
  > "$BACKUP_FILE"

# Pretty-print with jq
jq . "$BACKUP_FILE" > "${BACKUP_FILE}.tmp" && mv "${BACKUP_FILE}.tmp" "$BACKUP_FILE"

info "Backup saved: $BACKUP_FILE"
info "Current registries in cluster:"
jq '.auths | keys' "$BACKUP_FILE"

# ── Step 2: Validate new pull secret ─────────────────────────────────────────
section "Step 2/4 — Validate new pull secret"

# Check it is valid JSON with an auths key
jq -e '.auths' "$NEW_SECRET_FILE" > /dev/null 2>&1 \
  || error "File is not valid pull-secret JSON (missing .auths key)"

info "New secret registries:"
jq '.auths | keys' "$NEW_SECRET_FILE"

# Real image pull test
PULLER=""
command -v podman &>/dev/null && PULLER="podman"
command -v docker &>/dev/null && [[ -z "$PULLER" ]] && PULLER="docker"

if [[ -n "$PULLER" ]]; then
  info "Testing image pull against registry.redhat.io using $PULLER..."
  if $PULLER pull --authfile "$NEW_SECRET_FILE" registry.redhat.io/ubi8/ubi:latest; then
    info "Image pull succeeded — new pull secret is valid."
  else
    error "Image pull FAILED. The new pull secret may be invalid or expired.\nRotate it at: https://console.redhat.com/openshift/downloads"
  fi
else
  warn "Neither podman nor docker found — skipping image pull test."
  warn "It is strongly recommended to validate the pull secret before continuing."
  read -r -p "  Continue without pull test? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── Step 3: Merge with current cluster registries ────────────────────────────
section "Step 3/4 — Merge with existing registry credentials"

MERGED_FILE="${ROOT_DIR}/merged-pull-secret.json"

# Merge strategy:
#   - New pull secret auths take priority (overwrite RH registries with new token)
#   - Existing auths fill in anything NOT in the new secret (preserves IBM, custom registries)
jq -s '{auths: (.[0].auths + .[1].auths)}' \
  "$NEW_SECRET_FILE" "$BACKUP_FILE" > "$MERGED_FILE"

info "Merged registries (what will be applied to cluster):"
jq '.auths | keys' "$MERGED_FILE"

# Safety check: make sure we haven't lost any registries that were in the backup
MISSING=$(jq -r --slurpfile backup "$BACKUP_FILE" \
  '($backup[0].auths | keys) - (.auths | keys) | .[]' "$MERGED_FILE" || true)
if [[ -n "$MISSING" ]]; then
  warn "The following registries from the current secret are MISSING from the merge:"
  echo "$MISSING"
  read -r -p "  Continue anyway? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted. No changes made."; exit 0; }
fi

# ── Step 4: Seal for target environment ──────────────────────────────────────
section "Step 4/4 — Seal secret for ${ENV}"

OVERLAY_DIR="${ROOT_DIR}/gitops/overlays/${ENV}"
OUTPUT_FILE="${OVERLAY_DIR}/sealed-secret.yaml"

# Fetch cluster's Sealed Secrets public key
CERT_FILE=$(mktemp /tmp/sealed-secrets-cert-XXXXXX.pem)
trap 'rm -f "$CERT_FILE" "$MERGED_FILE"' EXIT

info "Fetching Sealed Secrets public key from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > "$CERT_FILE"

# Build the raw Secret in memory and pipe through kubeseal — merged secret never written as plain YAML
B64=$(base64 -w 0 < "$MERGED_FILE")

cat <<EOF | kubeseal \
  --cert "$CERT_FILE" \
  --scope cluster-wide \
  --format yaml \
  > "$OUTPUT_FILE"
apiVersion: v1
kind: Secret
metadata:
  name: pull-secret
  namespace: openshift-config
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${B64}
EOF

info "SealedSecret written: $OUTPUT_FILE"

# ── Done — print git commands ─────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✓ Pull secret rotation ready for ${ENV}${NC}"
echo ""
echo "  Run these git commands to trigger ArgoCD:"
echo ""
echo "    git add gitops/overlays/${ENV}/sealed-secret.yaml"
echo "    git commit -m \"chore: rotate pull secret for ${ENV} [$(date +%Y-%m-%d)]\""
echo "    git push"
echo ""
echo "  Then monitor the cluster:"
echo "    oc get mcp          # wait for UPDATED=True (crio restart, no node reboot)"
echo "    oc get co           # all operators should be Available"
echo "    oc get pods -A | grep -i imagepull   # should be empty"
echo ""
echo "  Backup saved at: ${BACKUP_DIR}/pull-secret-${ENV}-${TIMESTAMP}.json"
echo "  (gitignored — stays on your VDI only)"
