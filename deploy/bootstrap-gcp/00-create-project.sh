#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [PROJECT_ID] [PROJECT_NAME]

  PROJECT_ID    Optional. Globally unique GCP project ID (6-30 chars,
                lowercase letters/digits/hyphens). Falls back to env var
                \$PROJECT_ID, then auto-generated 'sre-challenge-<6 random>'.
  PROJECT_NAME  Optional. Human-readable display name (default: "SRE Challenge Lab").

Env vars (lower precedence than CLI args):
  PROJECT_ID, PROJECT_NAME, BILLING_ACCOUNT

Examples:
  $0                                  # auto-generate ID, prompt for billing
  $0 my-sre-lab                       # use given ID
  $0 my-sre-lab "My SRE Lab Project"  # ID + display name
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

PROJECT_ID="${1:-${PROJECT_ID:-}}"
PROJECT_NAME="${2:-${PROJECT_NAME:-SRE Challenge Lab}}"
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"

REQUIRED_APIS=(
  cloudresourcemanager.googleapis.com
  compute.googleapis.com
  container.googleapis.com           # GKE
  artifactregistry.googleapis.com    # Docker registry
  secretmanager.googleapis.com       # ESO backend
  dns.googleapis.com                 # Cloud DNS (optional, for real domains)
  cloudkms.googleapis.com            # CMEK for etcd + Secret Manager
  iam.googleapis.com                 # service accounts, WI
  iamcredentials.googleapis.com      # Workload Identity token issuance
  servicenetworking.googleapis.com   # private services access
  logging.googleapis.com
  monitoring.googleapis.com
  cloudbuild.googleapis.com          # `make jenkins` builds pre-baked Jenkins image via Cloud Build
  storage.googleapis.com             # Cloud Build artifact uploads
)

command -v gcloud >/dev/null || {
  echo "gcloud not found. Install: brew install --cask google-cloud-sdk" >&2
  exit 1
}

ACTIVE_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  echo "No active gcloud account. Run: gcloud auth login" >&2
  exit 1
fi
echo "==> Active gcloud account: ${ACTIVE_ACCOUNT}"

if [[ -z "${BILLING_ACCOUNT}" ]]; then
  echo "==> Available billing accounts:"
  gcloud beta billing accounts list --format='table(ACCOUNT_ID,DISPLAY_NAME,OPEN)' || {
    echo "Failed to list billing accounts. Make sure at least one exists" >&2
    echo "in https://console.cloud.google.com/billing" >&2
    exit 1
  }
  echo
  read -rp "Enter ACCOUNT_ID to use (e.g. XXXXXX-XXXXXX-XXXXXX): " BILLING_ACCOUNT
fi

if [[ -z "${PROJECT_ID}" ]]; then
  PROJECT_ID="sre-challenge-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
fi

echo "==> Project ID: ${PROJECT_ID}"

if gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    project already exists, skipping creation"
else
  echo "==> Creating project ${PROJECT_ID}"
  gcloud projects create "${PROJECT_ID}" --name="${PROJECT_NAME}"
fi

CURRENT_BILLING="$(gcloud beta billing projects describe "${PROJECT_ID}" \
  --format='value(billingAccountName)' 2>/dev/null | sed 's|billingAccounts/||' || true)"

if [[ "${CURRENT_BILLING}" == "${BILLING_ACCOUNT}" ]]; then
  echo "==> Billing already linked to ${BILLING_ACCOUNT}"
else
  echo "==> Linking billing account ${BILLING_ACCOUNT}"
  gcloud beta billing projects link "${PROJECT_ID}" \
    --billing-account="${BILLING_ACCOUNT}"
fi

gcloud config set project "${PROJECT_ID}" >/dev/null
echo "==> Set ${PROJECT_ID} as default gcloud project"

echo "==> Enabling ${#REQUIRED_APIS[@]} APIs (takes ~1-2 min on first run)"
gcloud services enable "${REQUIRED_APIS[@]}" --project="${PROJECT_ID}"

# ---- Terraform state bucket ----
# Remote state in GCS so the whole team apply against the same source of
# truth. GCS backend has native object-generation locking — concurrent
# `terraform apply` from two engineers is blocked, second one waits.
# Versioning keeps history of every change (rollback by restoring an
# older generation). Lifecycle deletes noncurrent versions after 30 days
# to cap storage cost. Public access blocked.
STATE_BUCKET="${PROJECT_ID}-tfstate"
STATE_LOCATION="${STATE_LOCATION:-EU}"

if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "==> State bucket gs://${STATE_BUCKET} already exists"
else
  echo "==> Creating Terraform state bucket gs://${STATE_BUCKET} (location: ${STATE_LOCATION})"
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${STATE_LOCATION}" \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

echo "==> Enable versioning on state bucket"
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning >/dev/null

echo "==> Lifecycle: delete noncurrent state versions after 30 days"
cat > /tmp/state-lifecycle.json <<EOF
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"daysSinceNoncurrentTime": 30, "numNewerVersions": 5}
    }
  ]
}
EOF
gcloud storage buckets update "gs://${STATE_BUCKET}" --lifecycle-file=/tmp/state-lifecycle.json >/dev/null
rm /tmp/state-lifecycle.json

# Write backend config so `terraform init -backend-config=backend.hcl` picks it up.
# Gitignored — bucket name is project-specific.
BACKEND_HCL="$(dirname "$0")/../terraform/backend.hcl"
cat > "${BACKEND_HCL}" <<EOF
bucket = "${STATE_BUCKET}"
prefix = "terraform/state"
EOF
echo "==> Wrote ${BACKEND_HCL}"

cat <<EOF

----------------------------------------------------------------------
Bootstrap done.

  Project ID:       ${PROJECT_ID}
  Billing account:  ${BILLING_ACCOUNT}
  Default region:   $(gcloud config get-value compute/region 2>/dev/null || echo '(unset)')

Next steps:
  cd deploy/terraform
  cp terraform.tfvars.example terraform.tfvars     # set project_id
  terraform init -backend-config=backend.hcl       # remote state in gs://${STATE_BUCKET}
  terraform plan
  terraform apply

State bucket: gs://${STATE_BUCKET}
  - versioning ON (history of every state change)
  - object-generation locking (concurrent applies blocked)
  - noncurrent versions deleted after 30 days
  - public access blocked
----------------------------------------------------------------------
EOF
