# Cloud KMS keyring + crypto-key. Reused for:
#   - GKE database encryption (etcd at rest) via application_layer_encryption
#   - Secret Manager CMEK on each secret created later
#
# Keyring is created in var.region — keys are bound to that location and
# cannot be moved. Lab/demo: HSM-backed (`protectionLevel = HSM`) is overkill
# and ~5x more expensive; software is fine.

resource "google_kms_key_ring" "main" {
  name     = "${var.cluster_name}-keyring"
  location = var.region
}

resource "google_kms_crypto_key" "etcd" {
  name     = "gke-etcd"
  key_ring = google_kms_key_ring.main.id
  purpose  = "ENCRYPT_DECRYPT"

  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false # set true in prod (destroying loses access to old etcd)
  }
}

# Grant the GKE service agent the right to use this key. Without this binding
# GKE refuses to create the cluster: "permission denied on KMS key".
data "google_iam_policy" "etcd_key_users" {
  binding {
    role = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
    members = [
      "serviceAccount:service-${data.google_project.this.number}@container-engine-robot.iam.gserviceaccount.com",
    ]
  }
}

resource "google_kms_crypto_key_iam_policy" "etcd" {
  crypto_key_id = google_kms_crypto_key.etcd.id
  policy_data   = data.google_iam_policy.etcd_key_users.policy_data
}

# Separate key for Secret Manager so rotation policies are independent.
resource "google_kms_crypto_key" "secrets" {
  name            = "secret-manager"
  key_ring        = google_kms_key_ring.main.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s"
}
