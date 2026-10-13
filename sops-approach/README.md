# Pull Secret Rotation — SOPS + Age approach
# Safe for public GitHub repos. No Sealed Secrets operator needed.
#
# How it works:
#   1. age key pair generated on your VDI (once)
#   2. age private key stored as a Secret on each cluster (once, via bootstrap)
#   3. ArgoCD helm-secrets plugin installed on ArgoCD (once, via bootstrap)
#   4. rotate-sops.sh merges + SOPS-encrypts the pull secret → writes ConfigMap YAML
#   5. git push → ArgoCD decrypts with age key → Job runs oc set data → done
#
# The encrypted file in GitHub looks like gibberish — safe even in a public repo.

## One-time setup per cluster
#
#   ./sops-approach/scripts/bootstrap-sops.sh uat
#
## Every rotation
#
#   ./sops-approach/scripts/rotate-sops.sh uat ./new-pull-secret.json
#   git add sops-approach/gitops/overlays/uat/pull-secret-cm.enc.yaml
#   git add sops-approach/gitops/base/rotation-job.yaml
#   git commit -m "chore: rotate pull secret for UAT"
#   git push
#   # ArgoCD decrypts → Job runs → pull-secret updated
