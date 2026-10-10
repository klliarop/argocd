# Pull Secret Rotation Runbook

## Overview

This runbook describes the full GitOps-based procedure for rotating the OpenShift global pull secret
across multiple clusters (UAT, PLD, DR) using ArgoCD and Sealed Secrets.

The pull secret lives in a single place on every cluster:
- **Namespace:** `openshift-config`
- **Secret name:** `pull-secret`
- **Key:** `.dockerconfigjson`

---

## Do nodes restart after the update?

**No** — as of OpenShift 4.7.4+, updating the global pull secret does **not** trigger a node drain
or reboot. The MCO applies a lightweight `MachineConfig` update that restarts only the `crio`
service on each node. Running workloads are not interrupted. New image pulls pick up the new
credentials immediately. You will see `MachineConfigPool` briefly show `UPDATING=True`; wait for
it to return to `UPDATED=True` before declaring success.

---

## Registries currently in the pull secret

Based on the existing cluster the following auths are present and **must be preserved** after rotation:

```
cloud.openshift.com   ← telemetry / Hybrid Cloud Console
cp.icr.io             ← IBM Cloud Pak images
quay.io               ← Red Hat Quay
registry.connect.redhat.com
registry.redhat.io
us.icr.io             ← IBM US regional registry
```

**Always merge** the new Red Hat pull secret with the existing credentials — never replace blindly.

---

## Architecture: GitOps flow

```
GitHub repo (this repo)
  └── gitops/
        ├── base/pull-secret/          ← shared Kustomize base
        └── overlays/
              ├── uat/                 ← SealedSecret encrypted for UAT cluster
              ├── pld/                 ← SealedSecret encrypted for PLD cluster
              └── dr/                  ← SealedSecret encrypted for DR  cluster

ArgoCD Application (one per cluster)
  └── watches overlays/<env>/
        └── on Git push → syncs SealedSecret to cluster
              └── Sealed Secrets controller decrypts → creates real Secret
                    └── openshift-config/pull-secret updated
```

**Why Sealed Secrets?**
- The `SealedSecret` YAML is safe to commit to Git — it is encrypted with the cluster's public key
- Only the Sealed Secrets controller running on that specific cluster can decrypt it
- No external secret store (Vault, AWS SM) needed — works standalone

---

## Prerequisites (one-time per cluster)

1. **Sealed Secrets controller** installed on every cluster:
   ```bash
   helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
   helm install sealed-secrets sealed-secrets/sealed-secrets \
     -n kube-system --set fullnameOverride=sealed-secrets-controller
   ```

2. **`kubeseal` CLI** installed on the operator's workstation:
   ```bash
   # Linux / macOS
   KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r .tag_name)
   curl -Lo kubeseal.tar.gz "https://github.com/bitnami-labs/sealed-secrets/releases/download/${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION#v}-linux-amd64.tar.gz"
   tar xf kubeseal.tar.gz kubeseal && sudo mv kubeseal /usr/local/bin/
   ```

3. **ArgoCD** installed and connected to this GitHub repo.

4. **`jq`** installed on the operator's workstation (used by the scripts).

---

## Step-by-step procedure (per cluster)

### Step 1 — Back up the current pull secret
```bash
./scripts/backup-pull-secret.sh
```
This saves `backups/pull-secret-<timestamp>.json` locally.

### Step 2 — Obtain and validate the new pull secret
Download `new-pull-secret.json` from https://console.redhat.com/openshift/downloads  
Then validate it:
```bash
./scripts/validate-pull-secret.sh ./new-pull-secret.json
```
This tests an actual image pull and shows which registries are in the file.

### Step 3 — Merge with existing credentials
The validate script also produces `merged-pull-secret.json` automatically.
Review it:
```bash
cat merged-pull-secret.json | jq '.auths | keys'
```
Confirm all expected registries are present.

### Step 4 — Seal the merged secret for the target cluster
```bash
# Make sure your kubeconfig is pointing at the target cluster first
./scripts/seal-pull-secret.sh uat    # or pld / dr
```
This writes `gitops/overlays/uat/sealed-secret.yaml` (encrypted for that cluster).

### Step 5 — Commit and push
```bash
git add gitops/overlays/uat/sealed-secret.yaml
git commit -m "chore: rotate pull secret for UAT [$(date +%Y-%m-%d)]"
git push
```

### Step 6 — ArgoCD syncs automatically
ArgoCD detects the change and applies the `SealedSecret`.  
The Sealed Secrets controller decrypts it and updates `openshift-config/pull-secret`.

### Step 7 — Verify
```bash
oc get clusteroperators
oc get mcp                          # wait for UPDATED=True
oc get nodes
oc get pods -A | grep -i imagepull  # should be empty
```

### Step 8 — Repeat for next environment
Repeat Steps 1–7 with `pld` and then `dr`.

---

## Entitlement linking (IBM Cloud Paks)

If `cp.icr.io` / `us.icr.io` credentials also need to be rotated, obtain the new IBM entitlement
key from https://myibm.ibm.com/products-services/containerlibrary and add it to the merged JSON
under `cp.icr.io` and `us.icr.io` before sealing.

Reference: https://www.ibm.com/docs/en/cloud-paks/rhos/1.0.0?topic=me-linking-red-hat-entitlements-from-your-cloud-paks

---

## Rollback

If something goes wrong after the update:
```bash
# Restore the backup directly (bypasses ArgoCD)
oc set data secret/pull-secret \
  -n openshift-config \
  --from-file=.dockerconfigjson=./backups/pull-secret-<timestamp>.json

# Then update Git to match (so ArgoCD doesn't re-apply the broken secret)
./scripts/seal-pull-secret.sh uat ./backups/pull-secret-<timestamp>.json
git add gitops/overlays/uat/sealed-secret.yaml
git commit -m "revert: restore pull secret backup for UAT"
git push
```
