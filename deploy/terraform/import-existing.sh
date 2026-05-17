#!/usr/bin/env bash
# Idempotently import resources that GCP keeps immutable across destroys.
# Run before `terraform apply` so a destroy → apply cycle doesn't 409 on KMS.
#
# Cloud KMS keyrings are not deletable; crypto keys go into a 24h "destroy
# scheduled" state. After `terraform destroy`, Terraform state forgets them,
# but the GCP side still has the keyring → next apply tries CREATE and gets
# 409 AlreadyExists. We bridge that by re-importing if-and-only-if needed.
set -euo pipefail

cd "$(dirname "$0")"

PROJECT_ID="$(terraform output -raw project_id 2>/dev/null || \
  grep -E '^\s*project_id\s*=' terraform.tfvars 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
REGION="$(terraform output -raw region 2>/dev/null || echo europe-central2)"
CLUSTER_NAME="$(grep -E '^\s*cluster_name\s*=' terraform.tfvars 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || echo sre-challenge)"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "import-existing: PROJECT_ID unknown — skipping (likely first-run, nothing to import)" >&2
  exit 0
fi

KEYRING="${CLUSTER_NAME}-keyring"
KEYRING_ID="projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KEYRING}"

import_if_missing() {
  local addr="$1" id="$2" out
  if out=$(terraform import "${addr}" "${id}" 2>&1); then
    echo "import-existing: imported ${addr}"
    return 0
  fi
  if grep -q 'already managed' <<<"${out}"; then
    return 0
  fi
  echo "${out}" >&2
  return 1
}

restore_destroyed_versions() {
  # After `terraform destroy`, key versions land in DESTROY_SCHEDULED (24h
  # grace). GKE/Secret Manager can't use the key in that state, so the next
  # apply 400s on encryption test. Restore everything in DESTROY_SCHEDULED
  # back to ENABLED.
  local key="$1"
  local versions
  versions=$(gcloud kms keys versions list \
    --key="${key}" --keyring="${KEYRING}" \
    --location="${REGION}" --project="${PROJECT_ID}" \
    --filter='state=DESTROY_SCHEDULED' --format='value(name)' 2>/dev/null || true)
  for v in ${versions}; do
    local vid="${v##*/}"
    echo "import-existing: restoring ${key} version ${vid} (was DESTROY_SCHEDULED)"
    gcloud kms keys versions restore "${vid}" \
      --key="${key}" --keyring="${KEYRING}" \
      --location="${REGION}" --project="${PROJECT_ID}" >/dev/null
    gcloud kms keys versions enable "${vid}" \
      --key="${key}" --keyring="${KEYRING}" \
      --location="${REGION}" --project="${PROJECT_ID}" >/dev/null
  done
}

if gcloud kms keyrings describe "${KEYRING}" \
     --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  import_if_missing google_kms_key_ring.main "${KEYRING_ID}"
  for key in etcd:gke-etcd secrets:secret-manager; do
    addr="google_kms_crypto_key.${key%%:*}"
    name="${key##*:}"
    if gcloud kms keys describe "${name}" --keyring="${KEYRING}" \
         --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
      import_if_missing "${addr}" "${KEYRING_ID}/cryptoKeys/${name}"
      restore_destroyed_versions "${name}"
    fi
  done
fi
