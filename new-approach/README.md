# Pull Secret Rotation — Job-based approach (no Sealed Secrets)

This is the simpler, OCP-native approach. Instead of fighting Sealed Secrets controller
ownership of `openshift-config/pull-secret`, ArgoCD syncs a Kubernetes Job that runs
`oc set data` directly — exactly the same command that works manually.

---

## How it works

```
Your VDI
  │
  ├── rotate-job.sh uat ./new-pull-secret.json
  │     └── merges registries
  │         base64-encodes merged secret
  │         writes gitops/overlays/uat/pull-secret-cm.yaml   (ConfigMap with encoded data)
  │
  ├── git add + commit + push
  │
  └── ArgoCD detects change
        syncs to cluster:
          - ConfigMap  (holds the new pull secret data)
          - Job        (runs oc set data once)
          - RBAC       (ServiceAccount + ClusterRoleBinding, one-time)
        Job pod runs:
          oc set data secret/pull-secret -n openshift-config \
            --from-file=.dockerconfigjson=/data/pull-secret
        pull-secret updated ✅
```

## Why this works where Sealed Secrets didn't

`openshift-config/pull-secret` is owned by OpenShift's cluster-version operator.
Sealed Secrets tries to become the owner of the Secret object itself — OCP refuses.
This Job approach never touches object ownership — it just patches the data inside
the secret using `oc set data`, exactly like a human would. OCP is fine with that.

---

## One-time setup per cluster

```bash
oc login <cluster>
./new-approach/scripts/bootstrap-job.sh uat
```

## Every rotation

```bash
oc login <cluster>
./new-approach/scripts/rotate-job.sh uat ./new-pull-secret.json
git add new-approach/gitops/overlays/uat/pull-secret-cm.yaml
git commit -m "chore: rotate pull secret for UAT"
git push
# ArgoCD syncs → Job runs → pull-secret updated
```
