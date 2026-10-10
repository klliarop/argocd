#!/usr/bin/env bash
# validate-pull-secret.sh
# Validates a new pull secret JSON file by:
#   1. Checking it is valid JSON with an "auths" key
#   2. Doing a real test image pull against registry.redhat.io
#   3. Merging it with the current cluster's pull secret (preserving IBM/other registries)
#      and writing merged-pull-secret.json in the project root.
#
# Usage:
#   ./scripts/validate-pull-secret.sh <path-to-new-pull-secret.json>
#
# Prerequisites: oc, jq, podman (or docker) on PATH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Argument check ────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-new-pull-secret.json>"
  exit 1
fi

NEW_SECRET_FILE="$(realpath "$1")"

if [[ ! -f "$NEW_SECRET_FILE" ]]; then
  echo "ERROR: File not found: $NEW_SECRET_FILE"
  exit 1
fi

echo "==> Using new pull secret: $NEW_SECRET_FILE"

# ── 1. Basic JSON validation ──────────────────────────────────────────────────
echo ""
echo "── Step 1: Validate JSON structure ──────────────────────────────────────"
if ! jq -e '.auths' "$NEW_SECRET_FILE" > /dev/null 2>&1; then
  echo "ERROR: File is not valid pull-secret JSON (missing .auths key)"
  exit 1
fi
echo "✓ Valid JSON. Registries in new secret:"
jq '.auths | keys' "$NEW_SECRET_FILE"

# ── 2. Test image pull ────────────────────────────────────────────────────────
echo ""
echo "── Step 2: Test image pull against registry.redhat.io ───────────────────"
TEST_IMAGE="registry.redhat.io/ubi8/ubi:latest"

PULLER=""
if command -v podman &>/dev/null; then
  PULLER="podman"
elif command -v docker &>/dev/null; then
  PULLER="docker"
else
  echo "WARNING: Neither podman nor docker found. Skipping image pull test."
fi

if [[ -n "$PULLER" ]]; then
  echo "==> Pulling $TEST_IMAGE using $PULLER..."
  if $PULLER pull --authfile "$NEW_SECRET_FILE" "$TEST_IMAGE"; then
    echo "✓ Image pull succeeded — new pull secret is valid."
  else
    echo "ERROR: Image pull failed. The new pull secret may be invalid or expired."
    echo "       Rotate it at: https://console.redhat.com/openshift/downloads"
    exit 1
  fi
fi

# ── 3. Merge with current cluster's pull secret ───────────────────────────────
echo ""
echo "── Step 3: Merge with current cluster pull secret ───────────────────────"
echo "==> Current cluster context: $(oc config current-context)"

CURRENT_SECRET_FILE=$(mktemp /tmp/current-pull-secret-XXXXXX.json)
trap 'rm -f "$CURRENT_SECRET_FILE"' EXIT

oc get secret/pull-secret \
  -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' \
  > "$CURRENT_SECRET_FILE"

echo "Registries currently in the cluster secret:"
jq '.auths | keys' "$CURRENT_SECRET_FILE"

MERGED_FILE="${ROOT_DIR}/merged-pull-secret.json"

# Merge strategy: new secret's auths take priority; existing auths fill in gaps
# Result: new RH credentials + preserved IBM/other registry credentials
jq -s '
  {auths: (.[0].auths + .[1].auths)}
' "$NEW_SECRET_FILE" "$CURRENT_SECRET_FILE" > "$MERGED_FILE"

echo ""
echo "✓ Merged secret written to: $MERGED_FILE"
echo "Registries in merged secret:"
jq '.auths | keys' "$MERGED_FILE"

echo ""
echo "==> Review $MERGED_FILE before sealing."
echo "    When ready, run:  ./scripts/seal-pull-secret.sh <env>"
echo "    where <env> is one of: uat, pld, dr"
