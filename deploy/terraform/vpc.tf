# Dedicated VPC for the cluster. Custom subnet (not auto-mode) so we control
# the CIDR plan and the secondary ranges that GKE will alias-IP pods/services
# into. VPC-native (alias IPs) is required for Workload Identity and is the
# only mode that supports private clusters cleanly.

resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.cluster_name}-nodes"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.vpc_cidr_nodes

  # Secondary ranges referenced by GKE ip_allocation_policy.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.vpc_cidr_pods
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.vpc_cidr_services
  }

  # Flow logs off in lab to save on Cloud Logging cost. In prod: enable with
  # aggregation_interval = INTERVAL_5_SEC, flow_sampling = 0.5.
  private_ip_google_access = true
}

# Cloud NAT — private nodes can reach the public internet (image pulls from
# gcr.io, gradle deps from Maven Central, github clone) without each node
# having its own external IP.
resource "google_compute_router" "nat_router" {
  name    = "${var.cluster_name}-nat-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
