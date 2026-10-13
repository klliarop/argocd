#!/usr/bin/env bash
# bootstrap-job.sh
# One-time setup per cluster for the Job-based pull secret rotation approach.
# No Sealed Secrets — just RBAC + ArgoCD Application.
#
# Usage:
#   ./new-approach/scripts/bootstrap-job.sh <env>
#   env: uat | pld | dr
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NEW_APPROACH_DIR="${ROOT_DIR}/new-approach"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}WARN:${NC} $*"; }
error()   { echo -e "${RED}ERROR:${NC} $*"; exit 1; }
section() { echo ""; echo "────────────────────────────────────────"; echo "  $*"; echo "────────────────────────────────────────"; }

[[ $# -lt 1 ]] && { echo "Usage: $0 <env>  (uat | pld | dr)"; exit 1; }
ENV="$1"
VALID_ENVS=("uat" "pld" "dr")
VALID=false
for v in "${VALID_ENVS[@]}"; do [[ "$ENV" == "$v" ]] && VALID=true && break; done
[[ "$VALID" == "false" ]] && error "Unknown environment '$ENV'."

ARGOCD_APP="${NEW_APPROACH_DIR}/argocd/app-${ENV}.yaml"
[[ ! -f "$ARGOCD_APP" ]] && error "ArgoCD app manifest not found: $ARGOCD_APP"

# ── Step 1: Verify login ──────────────────────────────────────────────────────
section "Step 1/4 — Verify cluster login"
CLUSTER_API=$(oc whoami --show-server)
info "Cluster : $CLUSTER_API"
info "User    : $(oc whoami)"
echo ""
read -r -p "  Bootstrap environment '$ENV' on this cluster? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Step 2: Apply RBAC ───────────────────────────────────────────────────────
section "Step 2/4 — Apply RBAC (ServiceAccount + ClusterRoleBinding)"
oc apply -f "${NEW_APPROACH_DIR}/gitops/base/serviceaccount.yaml"
oc apply -f "${NEW_APPROACH_DIR}/gitops/base/rbac.yaml"

# OCP: grant the rotator SA permission to patch openshift-config secrets
oc adm policy add-cluster-role-to-user cluster-admin \
  -z pull-secret-rotator \
  -n openshift-config 2>/dev/null || true

# Grant ArgoCD application controller permission to manage openshift-config
oc adm policy add-cluster-role-to-user cluster-admin \
  -z openshift-gitops-argocd-application-controller \
  -n openshift-gitops 2>/dev/null || true

info "RBAC applied."

# ── Step 3: Backup current pull secret ───────────────────────────────────────
section "Step 3/4 — Backup current pull secret"
BACKUP_DIR="${ROOT_DIR}/backups"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/pull-secret-${ENV}-${TIMESTAMP}.json"
oc get secret/pull-secret -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' \
  > "$BACKUP_FILE"
jq . "$BACKUP_FILE" > "${BACKUP_FILE}.tmp" && mv "${BACKUP_FILE}.tmp" "$BACKUP_FILE"
info "Backup: $BACKUP_FILE"
info "Registries:"
jq '.auths | keys' "$BACKUP_FILE"

# ── Step 4: Register ArgoCD Application ──────────────────────────────────────
section "Step 4/4 — Register ArgoCD Application for ${ENV}"
oc apply -f "$ARGOCD_APP"
info "ArgoCD Application applied."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✓ Bootstrap complete for ${ENV}${NC}"
echo ""
echo "  Next — rotate the pull secret:"
echo "    ./new-approach/scripts/rotate-job.sh ${ENV} ./new-pull-secret.json"
echo "    git add new-approach/gitops/overlays/${ENV}/pull-secret-cm.yaml"
echo "    git add new-approach/gitops/base/rotation-job.yaml"
echo "    git commit -m \"chore: rotate pull secret for ${ENV}\""
echo "    git push"
