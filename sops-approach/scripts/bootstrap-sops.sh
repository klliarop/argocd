#!/usr/bin/env bash
# bootstrap-sops.sh
# One-time setup per cluster for the SOPS + Age pull secret rotation approach.
#
# What it does:
#   1. Installs sops + age CLI on your VDI if missing
#   2. Generates an age key pair (if one doesn't exist yet)
#   3. Updates .sops.yaml with the generated public key
#   4. Stores the age PRIVATE key as a Secret on the cluster
#      (ArgoCD repo-server uses this to decrypt at sync time)
#   5. Patches ArgoCD repo-server to add the SOPS decryption plugin
#   6. Applies RBAC for the rotation Job ServiceAccount
#   7. Backs up current pull secret
#   8. Registers the ArgoCD Application
#
# Usage:
#   ./sops-approach/scripts/bootstrap-sops.sh <env>
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

[[ $# -lt 1 ]] && { echo "Usage: $0 <env>  (uat | pld | dr)"; exit 1; }
ENV="$1"
VALID_ENVS=("uat" "pld" "dr")
VALID=false
for v in "${VALID_ENVS[@]}"; do [[ "$ENV" == "$v" ]] && VALID=true && break; done
[[ "$VALID" == "false" ]] && error "Unknown environment '$ENV'."

# ── Step 1: Verify cluster login ──────────────────────────────────────────────
section "Step 1/7 — Verify cluster login"
CLUSTER_API=$(oc whoami --show-server)
info "Cluster : $CLUSTER_API"
info "User    : $(oc whoami)"
echo ""
read -r -p "  Bootstrap SOPS approach for '$ENV' on this cluster? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Step 2: Install sops + age on VDI ─────────────────────────────────────────
section "Step 2/7 — Install sops + age CLI on VDI"

if ! command -v sops &>/dev/null; then
  info "Installing sops..."
  wget -qO /tmp/sops \
    "https://github.com/getsops/sops/releases/download/v3.8.1/sops-v3.8.1.linux.amd64"
  chmod +x /tmp/sops
  sudo mv /tmp/sops /usr/local/bin/sops
  info "sops installed: $(sops --version)"
else
  info "sops : $(sops --version)"
fi

if ! command -v age &>/dev/null; then
  info "Installing age..."
  wget -qO /tmp/age.tar.gz \
    "https://github.com/FiloSottile/age/releases/download/v1.1.1/age-v1.1.1-linux-amd64.tar.gz"
  tar xf /tmp/age.tar.gz -C /tmp
  sudo mv /tmp/age/age /usr/local/bin/age
  sudo mv /tmp/age/age-keygen /usr/local/bin/age-keygen
  rm -rf /tmp/age /tmp/age.tar.gz
  info "age installed: $(age --version)"
else
  info "age : $(age --version)"
fi

# ── Step 3: Generate age key pair ─────────────────────────────────────────────
section "Step 3/7 — Generate age key pair"

AGE_KEY_FILE="${ROOT_DIR}/.age-key.txt"

if [[ -f "$AGE_KEY_FILE" ]]; then
  warn "Age key already exists: $AGE_KEY_FILE — skipping generation."
  AGE_PUBLIC_KEY=$(grep "public key:" "$AGE_KEY_FILE" | awk '{print $4}')
else
  info "Generating new age key pair..."
  age-keygen -o "$AGE_KEY_FILE"
  AGE_PUBLIC_KEY=$(grep "public key:" "$AGE_KEY_FILE" | awk '{print $4}')
  info "Public key : $AGE_PUBLIC_KEY"
  info "Private key: $AGE_KEY_FILE  ← NEVER commit this file"
fi

# Update .sops.yaml with the real public key
sed -i "s|age1REPLACE_WITH_YOUR_PUBLIC_KEY|${AGE_PUBLIC_KEY}|g" \
  "${SOPS_DIR}/.sops.yaml"
info ".sops.yaml updated with public key."

# ── Step 4: Store age private key on cluster ──────────────────────────────────
section "Step 4/7 — Store age private key on cluster"

oc create secret generic age-key \
  -n openshift-gitops \
  --from-file=key.txt="$AGE_KEY_FILE" \
  --dry-run=client -o yaml | oc apply -f -
info "age-key secret created/updated in openshift-gitops namespace."

# ── Step 5: Install SOPS plugin on ArgoCD repo-server ─────────────────────────
section "Step 5/7 — Install SOPS decryption plugin on ArgoCD"

oc apply -f "${SOPS_DIR}/argocd/argocd-sops-plugin.yaml"

info "Waiting for repo-server to restart..."
oc rollout restart deployment/openshift-gitops-repo-server -n openshift-gitops
oc rollout status deployment/openshift-gitops-repo-server -n openshift-gitops --timeout=3m
info "ArgoCD repo-server restarted with SOPS plugin."

# ── Step 6: Apply RBAC for rotation Job ───────────────────────────────────────
section "Step 6/7 — Apply RBAC"

oc apply -f "${SOPS_DIR}/gitops/base/rbac.yaml"
oc adm policy add-cluster-role-to-user cluster-admin \
  -z pull-secret-rotator -n openshift-config 2>/dev/null || true
oc adm policy add-cluster-role-to-user cluster-admin \
  -z openshift-gitops-argocd-application-controller \
  -n openshift-gitops 2>/dev/null || true
info "RBAC applied."

# ── Step 7: Backup + register ArgoCD Application ──────────────────────────────
section "Step 7/7 — Backup + register ArgoCD Application"

BACKUP_DIR="${ROOT_DIR}/backups"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/pull-secret-${ENV}-${TIMESTAMP}.json"
oc get secret/pull-secret -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' > "$BACKUP_FILE"
jq . "$BACKUP_FILE" > "${BACKUP_FILE}.tmp" && mv "${BACKUP_FILE}.tmp" "$BACKUP_FILE"
info "Backup: $BACKUP_FILE"

oc apply -f "${SOPS_DIR}/argocd/app-${ENV}.yaml"
info "ArgoCD Application registered."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✓ SOPS bootstrap complete for ${ENV}${NC}"
echo ""
echo "  IMPORTANT: Never commit .age-key.txt — it is the private key."
echo "  It is gitignored automatically."
echo ""
echo "  Next — rotate the pull secret:"
echo "    ./sops-approach/scripts/rotate-sops.sh ${ENV} ./new-pull-secret.json"
echo "    git add sops-approach/gitops/overlays/${ENV}/pull-secret-cm.enc.yaml"
echo "    git add sops-approach/gitops/base/rotation-job.yaml"
echo "    git commit -m \"chore: rotate pull secret for ${ENV}\""
echo "    git push"
