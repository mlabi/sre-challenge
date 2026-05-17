# Google service accounts (GSAs) used by the cluster and its workloads.
#
# Pattern: one GSA per concern, bound to a Kubernetes ServiceAccount via
# Workload Identity. Pods get GCP-side permissions through their KSA
# without ever holding a JSON key.

# ----- Node SA (per-node, not Workload Identity) -----
# The minimal SA the node pool itself runs as. Default 'Compute Engine
# default' SA is *editor*-level — way too much. This one has just what
# kubelet + container runtime need.

resource "google_service_account" "node" {
  account_id   = "${var.cluster_name}-node"
  display_name = "GKE node SA — minimal permissions"
}

resource "google_project_iam_member" "node_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_project_iam_member" "node_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_project_iam_member" "node_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.node.email}"
}

# Image pull from the Artifact Registry above. Scoped to the one repo, not
# project-wide.
resource "google_artifact_registry_repository_iam_member" "node_puller" {
  location   = google_artifact_registry_repository.main.location
  repository = google_artifact_registry_repository.main.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.node.email}"
}

# ----- ESO GSA (Workload Identity) -----
# external-secrets-operator pod talks to Secret Manager as this GSA.

resource "google_service_account" "eso" {
  account_id   = "${var.cluster_name}-eso"
  display_name = "ESO — Secret Manager access"
}

resource "google_project_iam_member" "eso_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.eso.email}"
}

# Workload Identity binding: KSA external-secrets/external-secrets
# impersonates this GSA. The KSA gets an annotation pointing at this GSA
# (set in k8s/eso/cluster-secret-store-gcpsm.yaml or via Helm values).
resource "google_service_account_iam_member" "eso_wi" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[external-secrets/external-secrets]"
}

# ----- Jenkins build GSA (Workload Identity) -----
# kaniko pods push images to Artifact Registry as this GSA.

resource "google_service_account" "jenkins_build" {
  account_id   = "${var.cluster_name}-jenkins-build"
  display_name = "Jenkins build agents — registry push"
}

resource "google_artifact_registry_repository_iam_member" "jenkins_build_writer" {
  location   = google_artifact_registry_repository.main.location
  repository = google_artifact_registry_repository.main.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.jenkins_build.email}"
}

resource "google_service_account_iam_member" "jenkins_build_wi" {
  service_account_id = google_service_account.jenkins_build.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[jenkins-build/jenkins]"
}
