# Artifact Registry — replaces the self-hosted distribution registry we ran
# in k3s. One Docker repo for everything (front/back/reader, plus the
# pre-baked Jenkins controller image). Workload Identity gives the Jenkins
# build agents push permission with no JSON keys.

resource "google_artifact_registry_repository" "main" {
  location      = var.region
  repository_id = var.registry_repository_id
  description   = "SRE challenge images — apps + pre-baked Jenkins"
  format        = "DOCKER"

  labels = var.labels

  cleanup_policies {
    id     = "keep-recent-tags"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }
}
