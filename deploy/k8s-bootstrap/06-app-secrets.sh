#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(cd deploy/terraform && terraform output -raw project_id)"

if ! gcloud secrets describe postgres-app-password --project="${PROJECT_ID}" >/dev/null 2>&1; then
  PW=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)
  printf '%s' "${PW}" | gcloud secrets create postgres-app-password \
    --project="${PROJECT_ID}" --replication-policy=automatic --data-file=-
fi

kubectl apply -f k8s/eso/secret-store-kafka.yaml
kubectl wait clustersecretstore/kafka-secrets --for=condition=Ready --timeout=2m

kubectl apply -f k8s/eso/external-secrets-front.yaml
kubectl apply -f k8s/eso/external-secrets-back.yaml

for ns in demo-back demo-reader; do
  cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-creds
  namespace: ${ns}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcpsm
    kind: ClusterSecretStore
  target:
    name: postgres-creds
    creationPolicy: Owner
    template:
      data:
        username: app
        password: "{{ .password }}"
  data:
    - secretKey: password
      remoteRef:
        key: postgres-app-password
EOF
done

for NS in demo-front demo-back demo-reader; do
  for ES in $(kubectl -n "${NS}" get externalsecret -o name 2>/dev/null); do
    kubectl -n "${NS}" wait "${ES}" --for=condition=Ready --timeout=2m
  done
done
