#!/usr/bin/env bash
set -euo pipefail

INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-4.11.3}"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version "${INGRESS_NGINX_VERSION}" \
  --set controller.service.type=LoadBalancer \
  --set controller.service.externalTrafficPolicy=Local \
  --set controller.metrics.enabled=true \
  --wait --timeout=5m

for i in $(seq 1 60); do
  LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "${LB_IP}" ]] && { echo "LB IP: ${LB_IP}  (ingress hostnames: *.${LB_IP}.nip.io)"; break; }
  sleep 5
done
[[ -n "${LB_IP}" ]] || { echo "Timed out waiting for LoadBalancer IP"; exit 1; }
