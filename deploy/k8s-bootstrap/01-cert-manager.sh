#!/usr/bin/env bash
set -euo pipefail

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.1}"
ACME_EMAIL="${ACME_EMAIL:-}"

if [[ -z "${ACME_EMAIL}" ]]; then
  if [[ -t 0 ]]; then
    read -rp "ACME_EMAIL for Let's Encrypt (real address — no example.com): " ACME_EMAIL
  fi
  if [[ -z "${ACME_EMAIL}" ]]; then
    echo "ACME_EMAIL still empty. Re-run with: ACME_EMAIL=you@yourdomain.tld $0" >&2
    exit 1
  fi
fi
if [[ "${ACME_EMAIL}" == *@example.com ]]; then
  echo "Let's Encrypt rejects example.com — provide a real address." >&2
  exit 1
fi

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --wait

kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=2m

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
      - http01:
          ingress:
            class: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-account
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
