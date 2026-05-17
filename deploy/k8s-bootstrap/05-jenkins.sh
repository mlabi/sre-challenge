#!/usr/bin/env bash
set -euo pipefail

JENKINS_CHART_VERSION="${JENKINS_CHART_VERSION:-5.9.19}"
JENKINS_IMAGE_TAG="${JENKINS_IMAGE_TAG:-2.555.2}"

PROJECT_ID="$(cd deploy/terraform && terraform output -raw project_id)"
REGISTRY_URL="$(cd deploy/terraform && terraform output -raw registry_url)"
INGRESS_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
INGRESS_DOMAIN="${INGRESS_IP}.nip.io"
JENKINS_HOST="jenkins.${INGRESS_DOMAIN}"

GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/mlabi/sre-challenge.git}"
GIT_BRANCH="${GIT_BRANCH:-gke-terraform}"

if ! gcloud secrets describe jenkins-admin-password --project="${PROJECT_ID}" >/dev/null 2>&1; then
  PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24)
  printf '%s' "${PASSWORD}" | gcloud secrets create jenkins-admin-password \
    --project="${PROJECT_ID}" --replication-policy=automatic --data-file=-
fi

if ! gcloud artifacts docker images describe \
     "${REGISTRY_URL}/jenkins:${JENKINS_IMAGE_TAG}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  CB_CONFIG=$(mktemp)
  trap "rm -f ${CB_CONFIG}" EXIT
  cat > "${CB_CONFIG}" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    args:
      - build
      - -t
      - ${REGISTRY_URL}/jenkins:${JENKINS_IMAGE_TAG}
      - -f
      - docker/Dockerfile.jenkins
      - .
images:
  - ${REGISTRY_URL}/jenkins:${JENKINS_IMAGE_TAG}
EOF
  gcloud builds submit --project="${PROJECT_ID}" --config="${CB_CONFIG}" .
fi

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace jenkins-build --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace jenkins \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest --overwrite
kubectl label namespace jenkins-build \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest --overwrite

JENKINS_BUILD_GSA="$(cd deploy/terraform && terraform output -raw jenkins_build_gsa_email)"
kubectl -n jenkins-build create serviceaccount jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins-build annotate sa jenkins \
  iam.gke.io/gcp-service-account="${JENKINS_BUILD_GSA}" --overwrite

# ConfigMap consumed via envFrom by Jenkinsfile agent pods (REGISTRY_URL +
# INGRESS_DOMAIN bash vars available to kaniko / helm stages).
kubectl -n jenkins-build create configmap sre-challenge-vars \
  --from-literal=REGISTRY_URL="${REGISTRY_URL}" \
  --from-literal=INGRESS_DOMAIN="${INGRESS_DOMAIN}" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: jenkins-admin
  namespace: jenkins
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcpsm
    kind: ClusterSecretStore
  target:
    name: jenkins-admin
    creationPolicy: Owner
    template:
      data:
        jenkins-admin-user: admin
        jenkins-admin-password: "{{ .password }}"
  data:
    - secretKey: password
      remoteRef:
        key: jenkins-admin-password
EOF
kubectl -n jenkins wait externalsecret/jenkins-admin --for=condition=Ready --timeout=2m

helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update jenkins >/dev/null

TMPVALS=$(mktemp)
trap "rm -f $TMPVALS" EXIT
REGISTRY_HOST="${REGISTRY_URL%%/*}" \
REGISTRY_PATH="${REGISTRY_URL#*/}" \
REGISTRY_URL="${REGISTRY_URL}" JENKINS_IMAGE_TAG="${JENKINS_IMAGE_TAG}" \
JENKINS_HOST="${JENKINS_HOST}" GIT_REPO_URL="${GIT_REPO_URL}" \
GIT_BRANCH="${GIT_BRANCH}" INGRESS_DOMAIN="${INGRESS_DOMAIN}" \
envsubst < deploy/k8s-bootstrap/jenkins-values.yaml.tpl > "${TMPVALS}"

helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins --version "${JENKINS_CHART_VERSION}" \
  -f "${TMPVALS}" \
  --set controller.admin.existingSecret=jenkins-admin \
  --set controller.admin.userKey=jenkins-admin-user \
  --set controller.admin.passwordKey=jenkins-admin-password \
  --wait --timeout=10m

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jenkins
  namespace: jenkins
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["${JENKINS_HOST}"]
      secretName: jenkins-tls
  rules:
    - host: ${JENKINS_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jenkins
                port:
                  number: 8080
EOF

kubectl apply -f k8s/jenkins/rbac-app-namespaces.yaml

echo "Jenkins ready at https://${JENKINS_HOST}/"
