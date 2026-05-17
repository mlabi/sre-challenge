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

tfvars_get() {
  grep -E "^\s*${1}\s*=" terraform.tfvars 2>/dev/null \
    | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true
}

PROJECT_ID="$(tfvars_get project_id)"
REGION="$(tfvars_get region)"
REGION="${REGION:-europe-central2}"
CLUSTER_NAME="$(tfvars_get cluster_name)"
CLUSTER_NAME="${CLUSTER_NAME:-sre-challenge}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "import-existing: project_id not set in terraform.tfvars — first run?" >&2
  exit 0
fi

echo "import-existing: PROJECT_ID=${PROJECT_ID} REGION=${REGION} CLUSTER=${CLUSTER_NAME}"

KEYRING="${CLUSTER_NAME}-keyring"
KEYRING_ID="projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KEYRING}"

import_if_missing() {
  local addr="$1" id="$2" out
  if out=$(terraform import "${addr}" "${id}" 2>&1); then
    echo "import-existing: imported ${addr}"
    return 0
  fi
  # Already in state — fine, nothing to do.
  if grep -q 'already managed' <<<"${out}"; then
    echo "import-existing: ${addr} already in state"
    return 0
  fi
  # Resource doesn't exist in GCP yet (first ever apply, or destroyed past
  # the 24h grace) — terraform will create it cleanly. Not an error.
  if grep -qE 'NotFound|does not exist|404' <<<"${out}"; then
    echo "import-existing: ${addr} not in GCP — terraform will create"
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

# Always try to import. terraform import is idempotent given the checks
# in import_if_missing (handles both "already in state" and "not in GCP").
# This is more robust than gating on a separate `gcloud describe` call —
# stale auth or transient gcloud errors used to make the gate silently
# false, then the apply would 409 on a resource that actually existed.
import_if_missing google_kms_key_ring.main "${KEYRING_ID}"
for key in etcd:gke-etcd secrets:secret-manager; do
  addr="google_kms_crypto_key.${key%%:*}"
  name="${key##*:}"
  import_if_missing "${addr}" "${KEYRING_ID}/cryptoKeys/${name}"
  restore_destroyed_versions "${name}"
done
