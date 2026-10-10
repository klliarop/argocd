#!/usr/bin/env bash
# seal-pull-secret.sh
# Seals merged-pull-secret.json (or a provided file) for a specific environment
# using kubeseal + the target cluster's public key.
# Writes the SealedSecret to gitops/overlays/<env>/sealed-secret.yaml
#
# Usage:
#   ./scripts/seal-pull-secret.sh <env> [path-to-secret.json]
#
#   <env>               : uat | pld | dr
#   [path-to-secret.json]: optional; defaults to ./merged-pull-secret.json
#
# Prerequisites:
#   - kubeconfig pointing at the TARGET cluster for <env>
#   - kubeseal CLI on PATH
#   - Sealed Secrets controller running on the target cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Argument check ────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <env> [path-to-secret.json]"
  echo "  env: uat | pld | dr"
  exit 1
fi

ENV="$1"
SECRET_FILE="${2:-${ROOT_DIR}/merged-pull-secret.json}"

VALID_ENVS=("uat" "pld" "dr")
VALID=false
for v in "${VALID_ENVS[@]}"; do
  [[ "$ENV" == "$v" ]] && VALID=true && break
done

if [[ "$VALID" == "false" ]]; then
  echo "ERROR: Unknown environment '$ENV'. Must be one of: uat, pld, dr"
  exit 1
fi

if [[ ! -f "$SECRET_FILE" ]]; then
  echo "ERROR: Secret file not found: $SECRET_FILE"
  echo "       Run ./scripts/validate-pull-secret.sh first to generate merged-pull-secret.json"
  exit 1
fi

# ── Check kubeseal ────────────────────────────────────────────────────────────
if ! command -v kubeseal &>/dev/null; then
  echo "ERROR: kubeseal is not installed. See docs/pull-secret-rotation-runbook.md for install instructions."
  exit 1
fi

OVERLAY_DIR="${ROOT_DIR}/gitops/overlays/${ENV}"
OUTPUT_FILE="${OVERLAY_DIR}/sealed-secret.yaml"

echo "==> Environment  : $ENV"
echo "==> Source secret: $SECRET_FILE"
echo "==> Output file  : $OUTPUT_FILE"
echo "==> Cluster ctx  : $(oc config current-context)"
echo ""

# ── Fetch the cluster's Sealed Secrets public key ─────────────────────────────
# We fetch the cert so the sealing is done offline/reproducibly.
CERT_FILE=$(mktemp /tmp/sealed-secrets-cert-XXXXXX.pem)
trap 'rm -f "$CERT_FILE"' EXIT

echo "==> Fetching Sealed Secrets controller public key from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > "$CERT_FILE"

echo "✓ Certificate fetched."

# ── Build a plain Kubernetes Secret manifest in memory, then seal it ──────────
# We use a here-doc to construct the Secret, then pipe it through kubeseal.
# This avoids writing the raw secret to disk.
echo ""
echo "==> Sealing secret..."

# Base64-encode the JSON content for the Secret manifest
B64=$(base64 -w 0 < "$SECRET_FILE")

# Pipe the raw Secret through kubeseal — never touches disk
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

echo "✓ SealedSecret written to: $OUTPUT_FILE"
echo ""
echo "==> Next steps:"
echo "    1. Review the file:  cat $OUTPUT_FILE"
echo "    2. Commit and push:"
echo "       git add $OUTPUT_FILE"
echo "       git commit -m \"chore: rotate pull secret for ${ENV} [$(date +%Y-%m-%d)]\""
echo "       git push"
echo "    3. ArgoCD will detect the change and sync automatically."
echo "       Monitor: oc get mcp && oc get co"
