#!/usr/bin/env bash
set -euo pipefail

STRIMZI_VERSION="${STRIMZI_VERSION:-0.51.0}"
CNPG_VERSION="${CNPG_VERSION:-0.22.1}"

kubectl apply -f k8s/namespaces.yaml

# Baseline NetworkPolicy (default-deny + DNS + k8s API egress) per managed ns.
# Without this, helm-chart-rendered per-app NPs (e.g. back-egress-postgres) trap
# the pod in a deny-everything-else state, including kube-dns lookups.
for ns in kafka postgres demo-front demo-back demo-reader external-secrets cert-manager kafka-operator cnpg-system ingress-nginx jenkins jenkins-build; do
  kubectl apply -n "$ns" -f k8s/network-policies/00-baseline.yaml
done

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
kubectl apply -f k8s/postgres/

kubectl -n kafka wait kafka/demo --for=condition=Ready --timeout=5m
kubectl -n postgres wait cluster.postgresql.cnpg.io/demo-pg --for=condition=Ready --timeout=5m
