#!/usr/bin/env bash
set -euo pipefail

STRIMZI_VERSION="${STRIMZI_VERSION:-0.51.0}"
CNPG_VERSION="${CNPG_VERSION:-0.28.2}"

kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/quotas.yaml

# Baseline NetworkPolicy (default-deny + DNS + k8s API egress + GKE metadata
# server egress for Workload Identity) per managed ns. Without these, helm-
# chart-rendered per-app NPs (e.g. back-egress-postgres) trap the pod in a
# deny-everything-else state, including kube-dns lookups.
for ns in kafka postgres demo-front demo-back demo-reader external-secrets cert-manager kafka-operator cnpg-system ingress-nginx jenkins jenkins-build; do
  kubectl apply -n "$ns" -f k8s/network-policies/00-baseline.yaml
done

# Per-component NetworkPolicies. These open the specific paths that managed
# components need on top of the baseline default-deny:
#   - external-secrets.yaml: egress to Google APIs (sts/iamcredentials/SM),
#     ingress from konnectivity-agent for ESO admission webhook.
#   - operators.yaml: same konnectivity-agent ingress for CNPG + cert-manager
#     webhooks; egress from operator pods to their managed namespaces.
#   - jenkins-build.yaml: kaniko egress to the public registry, plus build
#     pod egress to the Jenkins controller and demo namespaces for smoke.
kubectl apply -f k8s/network-policies/external-secrets.yaml
kubectl apply -f k8s/network-policies/operators.yaml
kubectl apply -f k8s/network-policies/jenkins-build.yaml
kubectl apply -f k8s/network-policies/ingress-nginx.yaml
kubectl apply -f k8s/network-policies/jenkins.yaml
kubectl apply -f k8s/network-policies/kafka.yaml
kubectl apply -f k8s/network-policies/postgres.yaml

helm repo add strimzi https://strimzi.io/charts/ >/dev/null 2>&1 || true
helm repo update strimzi >/dev/null

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
curl -sSLf "https://github.com/strimzi/strimzi-kafka-operator/releases/download/${STRIMZI_VERSION}/strimzi-${STRIMZI_VERSION}.tar.gz" \
  -o "${TMPDIR}/strimzi.tgz"
tar -xzf "${TMPDIR}/strimzi.tgz" -C "${TMPDIR}"
cat "${TMPDIR}/strimzi-${STRIMZI_VERSION}/install/cluster-operator/"04*-Crd-*.yaml \
  | kubectl apply --server-side --force-conflicts -f -

helm upgrade --install strimzi strimzi/strimzi-kafka-operator \
  --namespace kafka-operator --create-namespace \
  --version "${STRIMZI_VERSION}" \
  --set watchAnyNamespace=true \
  --wait

helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null

helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --version "${CNPG_VERSION}" \
  --wait

kubectl apply -f k8s/kafka/

# Seed the CNPG bootstrap secret for user 'app' from Secret Manager BEFORE
# applying the postgres Cluster. CNPG honours an existing secret instead of
# generating a random password, so the secret postgres-creds ExternalSecret
# pulls (same SM key) ends up matching the role password — no post-init
# ALTER USER needed.
PROJECT_ID="$(cd deploy/terraform && terraform output -raw project_id)"
if ! gcloud secrets describe postgres-app-password --project="${PROJECT_ID}" >/dev/null 2>&1; then
  PW=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)
  printf '%s' "${PW}" | gcloud secrets create postgres-app-password \
    --project="${PROJECT_ID}" --replication-policy=automatic --data-file=-
fi
PG_PW=$(gcloud secrets versions access latest \
  --secret=postgres-app-password --project="${PROJECT_ID}")
kubectl -n postgres create secret generic demo-pg-app \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=app \
  --from-literal=password="${PG_PW}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/postgres/

kubectl -n kafka wait kafka/demo --for=condition=Ready --timeout=5m
kubectl -n postgres wait cluster.postgresql.cnpg.io/demo-pg --for=condition=Ready --timeout=5m
