output "project_id" {
  value = var.project_id
}

output "cluster_name" {
  value = google_container_cluster.main.name
}

output "cluster_location" {
  value = google_container_cluster.main.location
}

output "registry_url" {
  description = "Artifact Registry Docker push/pull base — used by Jenkinsfile + helm image.repository"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.main.repository_id}"
}

output "kubeconfig_command" {
  description = "Run this once to register kubectl context against the new cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --zone ${google_container_cluster.main.location} --project ${var.project_id}"
}

output "eso_gsa_email" {
  value = google_service_account.eso.email
}

output "jenkins_build_gsa_email" {
  value = google_service_account.jenkins_build.email
}

output "kms_secret_key" {
  description = "Use this when creating Secret Manager secrets (CMEK)"
  value       = google_kms_crypto_key.secrets.id
}
