# ==============================================================================
# All knobs for the GKE deployment in one place. Defaults are picked for a
# cheap demo run (~$70/mo at 24/7, much less if you destroy between sessions).
# ==============================================================================

variable "project_id" {
  description = "GCP project ID (from bootstrap-gcp/00-create-project.sh)"
  type        = string
}

variable "region" {
  description = "GCP region. europe-central2 (Warsaw) for low latency from PL"
  type        = string
  default     = "europe-central2"
}

variable "zone" {
  description = "Zone for the (zonal) GKE cluster. Pick one inside var.region"
  type        = string
  default     = "europe-central2-a"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "sre-challenge"
}

# ----- Networking -----

variable "vpc_cidr_nodes" {
  description = "Primary subnet CIDR for node IPs"
  type        = string
  default     = "10.10.0.0/22"
}

variable "vpc_cidr_pods" {
  description = "Secondary range for pod IPs (VPC-native, alias)"
  type        = string
  default     = "10.20.0.0/16"
}

variable "vpc_cidr_services" {
  description = "Secondary range for ClusterIP services"
  type        = string
  default     = "10.30.0.0/20"
}

variable "master_authorized_cidr" {
  description = "Single CIDR allowed to reach the GKE control plane (your IP/32)"
  type        = string
  # Default is your public IP /32 — find it with: curl -s ifconfig.me
  # 0.0.0.0/0 works for a wide-open demo but it's a soft warning sign.
  default     = "0.0.0.0/0"
}

# ----- Node pool -----

variable "node_machine_type" {
  description = "GCE machine type for cluster nodes. e2-standard-4 = 4vCPU/16GB"
  type        = string
  default     = "e2-standard-4"
}

variable "node_count_min" {
  description = "Cluster autoscaler minimum nodes"
  type        = number
  default     = 1
}

variable "node_count_max" {
  description = "Cluster autoscaler maximum nodes (peak during Jenkins build)"
  type        = number
  default     = 3
}

variable "node_disk_size_gb" {
  description = "Boot disk per node — fits k8s system pods + scratch"
  type        = number
  default     = 50
}

# ----- Artifact Registry -----

variable "registry_repository_id" {
  description = "Artifact Registry Docker repo name"
  type        = string
  default     = "sre-challenge"
}

# ----- Labels (applied to all resources for cost/audit grouping) -----

variable "labels" {
  description = "Labels merged into every resource"
  type        = map(string)
  default = {
    managed-by = "terraform"
    project    = "sre-challenge"
    env        = "lab"
  }
}
