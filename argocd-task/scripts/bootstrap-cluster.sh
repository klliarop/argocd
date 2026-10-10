#!/usr/bin/env bash
# bootstrap-cluster.sh
# One-time setup for a cluster. Run once per cluster, never again.
#
# What it does:
#   1. Checks prerequisites on YOUR VDI (helm, kubeseal, oc, jq)
#   2. Installs kubeseal CLI on your VDI if missing
#   3. Installs the Sealed Secrets controller on the connected cluster via Helm
#   4. Backs up the current pull secret from that cluster
#   5. Applies the ArgoCD Application manifest for this environment
#      (so ArgoCD starts watching Git for this cluster)
#
# Usage:
#   ./scripts/bootstrap-cluster.sh <env>
#   where <env> is: uat | pld | dr
#
# Prerequisites:
#   - oc CLI logged in to the target cluster with cluster-admin
#   - helm CLI on PATH
#   - ArgoCD already running on the cluster (or a hub cluster)
#   - This repo already pushed to GitHub and repoURL set in argocd/app-<env>.yaml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Colours for readability ───────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()    { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}WARN:${NC} $*"; }
error()   { echo -e "${RED}ERROR:${NC} $*"; exit 1; }
section() { echo ""; echo "────────────────────────────────────────"; echo "  $*"; echo "────────────────────────────────────────"; }

# ── Argument check ────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <env>"
  echo "  env: uat | pld | dr"
  exit 1
fi

ENV="$1"
VALID_ENVS=("uat" "pld" "dr")
VALID=false
for v in "${VALID_ENVS[@]}"; do [[ "$ENV" == "$v" ]] && VALID=true && break; done
[[ "$VALID" == "false" ]] && error "Unknown environment '$ENV'. Must be one of: uat, pld, dr"

ARGOCD_APP="${ROOT_DIR}/argocd/app-${ENV}.yaml"
[[ ! -f "$ARGOCD_APP" ]] && error "ArgoCD app manifest not found: $ARGOCD_APP"

# ── Step 1: Check cluster login ───────────────────────────────────────────────
section "Step 1/5 — Verify cluster login"
CLUSTER_CTX=$(oc config current-context 2>/dev/null || true)
[[ -z "$CLUSTER_CTX" ]] && error "Not logged in to any cluster. Run: oc login <cluster-api-url>"

CLUSTER_API=$(oc whoami --show-server)
info "Cluster context : $CLUSTER_CTX"
info "Cluster API     : $CLUSTER_API"
info "Logged in as    : $(oc whoami)"

# Confirm with operator
echo ""
echo "  You are about to bootstrap environment: ${ENV}"
echo "  Target cluster: ${CLUSTER_API}"
echo ""
read -r -p "  Is this correct? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Step 2: Check/install VDI prerequisites ───────────────────────────────────
section "Step 2/5 — Check VDI prerequisites"

# jq
if ! command -v jq &>/dev/null; then
  error "jq is not installed. Install it first: https://stedolan.github.io/jq/download/"
fi
info "jq        : $(jq --version)"

# helm — install automatically from Red Hat CDN if missing
if ! command -v helm &>/dev/null; then
  warn "helm not found — installing now..."
  HELM_TGZ=$(mktemp /tmp/helm-XXXXXX.tar.gz)
  wget -qO "$HELM_TGZ" \
    "https://developers.redhat.com/content-gateway/file/pub/cgw/helm/3.22.0-90/helm-linux-amd64.tar.gz" \
    || { error "Failed to download helm. Check network connectivity and try again."; }
  tar -xzvf "$HELM_TGZ" -C /tmp helm-linux-amd64
  sudo mv /tmp/helm-linux-amd64 /usr/local/bin/helm
  rm -f "$HELM_TGZ"
  info "helm installed: $(helm version --short)"
else
  info "helm      : $(helm version --short)"
fi

# oc
info "oc        : $(oc version --client -o json | jq -r '.clientVersion.gitVersion')"

# kubeseal — install automatically if missing
if ! command -v kubeseal &>/dev/null; then
  warn "kubeseal not found — installing now..."
  KUBESEAL_VERSION="0.27.2"
  info "Downloading kubeseal ${KUBESEAL_VERSION}..."
  wget -O /tmp/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz \
    "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
    || { error "Failed to download kubeseal. Check network connectivity."; }
  tar -xvzf /tmp/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz -C /tmp kubeseal
  sudo mv /tmp/kubeseal /usr/local/bin/kubeseal
  rm -f /tmp/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz
  info "kubeseal installed: $(kubeseal --version)"
else
  info "kubeseal  : $(kubeseal --version)"
fi

# ── Step 3: Install Sealed Secrets controller on cluster ──────────────────────
section "Step 3/5 — Install Sealed Secrets controller on cluster"

SEALED_SECRETS_NS="kube-system"

# Check if already installed by looking for the controller deployment
if oc get deployment sealed-secrets-controller -n "$SEALED_SECRETS_NS" &>/dev/null; then
  info "Sealed Secrets controller already installed — skipping."
else
  info "Installing Sealed Secrets controller via manifest (no Helm repo needed)..."
  KUBESEAL_VERSION="0.27.2"
  MANIFEST_URL="https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/controller.yaml"

  info "Downloading manifest from: $MANIFEST_URL"
  wget -qO /tmp/sealed-secrets-controller.yaml "$MANIFEST_URL" \
    || { error "Failed to download Sealed Secrets manifest. Check network connectivity."; }

  oc apply -f /tmp/sealed-secrets-controller.yaml
  rm -f /tmp/sealed-secrets-controller.yaml
  info "Sealed Secrets controller manifest applied."
fi

# Verify the controller pod is running
info "Verifying controller pod is scheduled (waiting up to 60s)..."
sleep 5
oc wait pod \
  -n "$SEALED_SECRETS_NS" \
  -l name=sealed-secrets-controller \
  --for=condition=Ready \
  --timeout=120s
info "Controller is Ready."

# ── Step 4: Back up current pull secret ───────────────────────────────────────
section "Step 4/5 — Back up current pull secret"
"${SCRIPT_DIR}/backup-pull-secret.sh"

# ── Step 5: Apply ArgoCD Application ──────────────────────────────────────────
section "Step 5/5 — Register ArgoCD Application for ${ENV}"

# Check the placeholder is replaced
if grep -q '<your-org>' "$ARGOCD_APP"; then
  warn "argocd/app-${ENV}.yaml still contains placeholder values."
  warn "Edit it first:"
  warn "  repoURL: https://github.com/<your-org>/<your-repo>.git"
  warn "  server:  https://api.<your-cluster>.com:6443"
  echo ""
  read -r -p "  Open the file now and press Enter when done, or type 'skip' to skip ArgoCD registration: " SKIP
  if [[ "$SKIP" == "skip" ]]; then
    warn "Skipped ArgoCD registration. Run: oc apply -f argocd/app-${ENV}.yaml when ready."
  else
    oc apply -f "$ARGOCD_APP"
    info "ArgoCD Application applied."
  fi
else
  oc apply -f "$ARGOCD_APP"
  info "ArgoCD Application applied."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✓ Bootstrap complete for environment: ${ENV}${NC}"
echo ""
echo "  Next step — rotate the pull secret:"
echo "    1. Download new-pull-secret.json from https://console.redhat.com/openshift/downloads"
echo "    2. Run: ./scripts/rotate-pull-secret.sh ${ENV} ./new-pull-secret.json"
echo "    3. git add gitops/overlays/${ENV}/sealed-secret.yaml"
echo "    4. git commit -m \"chore: rotate pull secret for ${ENV}\""
echo "    5. git push"
echo "    → ArgoCD will propagate the change to the cluster automatically."
