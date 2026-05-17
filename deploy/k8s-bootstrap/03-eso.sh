#!/usr/bin/env bash
set -euo pipefail

ESO_VERSION="${ESO_VERSION:-0.10.7}"

ESO_GSA_EMAIL="$(cd deploy/terraform && terraform output -raw eso_gsa_email)"
PROJECT_ID="$(cd deploy/terraform && terraform output -raw project_id)"
CLUSTER_NAME="$(cd deploy/terraform && terraform output -raw cluster_name)"
CLUSTER_LOCATION="$(cd deploy/terraform && terraform output -raw cluster_location)"

helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --version "${ESO_VERSION}" \
  --set installCRDs=true \
  --set serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="${ESO_GSA_EMAIL}" \
  --wait

kubectl -n external-secrets rollout status deploy/external-secrets-webhook --timeout=2m

sed -e "s|PROJECT_ID_FROM_TF|${PROJECT_ID}|g" \
    -e "s|CLUSTER_LOCATION_FROM_TF|${CLUSTER_LOCATION}|g" \
    -e "s|CLUSTER_NAME_FROM_TF|${CLUSTER_NAME}|g" \
    k8s/eso/cluster-secret-store-gcpsm.yaml | kubectl apply -f -

kubectl wait clustersecretstore/gcpsm --for=condition=Ready --timeout=2m
