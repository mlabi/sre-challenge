# GKE Standard cluster. Zonal (cheaper, no HA across zones — see runbook for
# the trade-off). Workload Identity ON; NetworkPolicy enforced via Dataplane
# V2 (eBPF, replaces Calico); private nodes (no public IPs, egress via NAT);
# control plane in a Google-managed VPC reachable only from var.master_authorized_cidr.

resource "google_container_cluster" "main" {
  provider = google-beta

  name     = var.cluster_name
  location = var.zone

  # Don't run the default node pool; we attach our own below.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  # VPC-native (alias IPs) — required for Workload Identity, private cluster,
  # and most of the modern GKE features.
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private cluster: no public IPs on nodes; control plane endpoint reachable
  # only from master_authorized_cidr. enable_private_endpoint=false keeps the
  # public control-plane endpoint up so we can kubectl from outside, locked
  # down to one IP by master_authorized_networks_config.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.master_authorized_cidr
      display_name = "operator"
    }
  }

  # Dataplane V2 — eBPF-based, native NetworkPolicy support without Calico.
  datapath_provider = "ADVANCED_DATAPATH"
  # network_policy block is redundant when datapath_provider=ADVANCED_DATAPATH
  # (V2 always enforces). Set it explicitly so future readers don't wonder.
  network_policy {
    enabled = false # disabled = managed by Dataplane V2, not the deprecated Calico add-on
  }

  # Workload Identity — the per-pod GCP auth mechanism we use everywhere
  # instead of mounting SA JSON keys.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # etcd application-layer secrets encryption with our KMS key.
  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.etcd.id
  }

  # Built-in features
  release_channel {
    channel = "STABLE"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  # Disable basic-auth + client cert (deprecated, security smell)
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Shielded nodes — secure boot + integrity monitoring on each node.
  enable_shielded_nodes = true

  # Cost: by default Google bills $0.10/hour per cluster for autopilot/standard.
  # No control over that, just noting it.

  deletion_protection = false # set true in prod
  resource_labels     = var.labels
}

# Single managed node pool. autoscaling 1..3, e2-standard-4 by default.
resource "google_container_node_pool" "main" {
  name       = "${var.cluster_name}-pool"
  cluster    = google_container_cluster.main.id
  node_count = null

  autoscaling {
    min_node_count = var.node_count_min
    max_node_count = var.node_count_max
  }

  management {
    auto_upgrade = true
    auto_repair  = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
    strategy        = "SURGE"
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = "pd-balanced"

    service_account = google_service_account.node.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA" # required for Workload Identity from pods
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = var.labels

    tags = ["${var.cluster_name}-node"]
  }
}
