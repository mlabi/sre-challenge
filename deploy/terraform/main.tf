# Provider config + project-level data sources.
#
# Project creation and API enablement happen out-of-band in
# deploy/bootstrap-gcp/00-create-project.sh. Terraform takes over once the
# project exists and APIs are on — keeping the chicken-and-egg of
# "service-usage API needed to enable services" out of the TF state.

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

data "google_project" "this" {
  project_id = var.project_id
}
