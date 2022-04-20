provider "google-beta" {
  project = var.project
  region  = var.default_region
}

resource "google_project_service" "enabled-services" {
  project            = var.project
  service            = each.key
  for_each           = toset(["compute.googleapis.com", "artifactregistry.googleapis.com", "run.googleapis.com"])
  disable_on_destroy = false

}
#Create a service in us-central1 or a region of your choice, configured through variables.
resource "google_cloud_run_service" "demo-webapp-primary" {
  name     = "demo-webapp-primary"
  provider = google-beta
  location = var.region_primary
  project  = var.project
  metadata {
    annotations = {
      "run.googleapis.com/ingress" = "internal-and-cloud-load-balancing"
    }
  }
  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale"  = "1000"
        "autoscaling.knative.dev/min-scale" = "3"
      }
    }
    spec {
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
      }
    }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
  depends_on = [
    google_project_service.enabled-services
  ]
}
#Create a service in us-east1 or a region of your choice, configured through vriables.
resource "google_cloud_run_service" "demo-webapp-secondary" {
  name     = "demo-webapp-secondary"
  provider = google-beta
  location = var.region_secondary
  project  = var.project
  metadata {
    annotations = {
      "run.googleapis.com/ingress" = "internal-and-cloud-load-balancing"
    }
  }
  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale"  = "1000"
        "autoscaling.knative.dev/min-scale" = "3"
      }
    }
    spec {
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
      }
    }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
  depends_on = [
    google_project_service.enabled-services
  ]
}

#Allow unauthenticated calls to services from the internet.
resource "google_cloud_run_service_iam_member" "member-primary-service" {
  location = google_cloud_run_service.demo-webapp-primary.location
  project  = google_cloud_run_service.demo-webapp-primary.project
  service  = google_cloud_run_service.demo-webapp-primary.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

#Allow unauthenticated calls to services from the internet.
resource "google_cloud_run_service_iam_member" "member-secondary-service" {
  location = google_cloud_run_service.demo-webapp-secondary.location
  project  = google_cloud_run_service.demo-webapp-secondary.project
  service  = google_cloud_run_service.demo-webapp-secondary.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# IP address will be generated outside of terraform and will be kept static, it will be configured on the load balancer to use.
# #Reserve the external IP address, this will be assigned to GCLB forwarding rule.
# resource "google_compute_global_address" "global-ip-address" {
#   provider     = google-beta
#   name         = "managed-cloud-run-lb-ext-ip"
#   ip_version   = "IPV4"
#   address_type = "EXTERNAL"
# }

resource "google_compute_managed_ssl_certificate" "global-sslcert" {
  name    = "global-sslcert"
  project = var.project
  managed {
    domains = [var.cloud_ep_domain]
  }
  provisioner "local-exec" {
    command = "sleep 600"
  }
}

#Create a serverless neg for CloudRun service in the primary region.
resource "google_compute_region_network_endpoint_group" "cloudrun-neg-primary" {
  project               = var.project
  name                  = "cloudrun-neg-primary"
  network_endpoint_type = "SERVERLESS"
  region                = var.region_primary
  cloud_run {
    service = google_cloud_run_service.demo-webapp-primary.name
  }
}

#Create a serverless neg for CloudRun service in the secondary region.
resource "google_compute_region_network_endpoint_group" "cloudrun-neg-secondary" {
  project               = var.project
  name                  = "cloudrun-neg-secondary"
  network_endpoint_type = "SERVERLESS"
  region                = var.region_secondary
  cloud_run {
    service = google_cloud_run_service.demo-webapp-secondary.name
  }
}

#Create a backend service with two backends, configure CloudRun services as NEGs.
resource "google_compute_backend_service" "cloud-run-global-lb-backend-service" {
  provider = google-beta
  name     = "cloud-run-global-backend-service"
  backend {
    group = google_compute_region_network_endpoint_group.cloudrun-neg-primary.id
  }
  backend {
    group = google_compute_region_network_endpoint_group.cloudrun-neg-secondary.id
  }
}

#Create a URL map which uses the backend service.
resource "google_compute_url_map" "cloud-run-global-lb" {
  project         = var.project
  name            = "cloud-run-global-lb"
  default_service = google_compute_backend_service.cloud-run-global-lb-backend-service.id
  path_matcher {
    path_rule {
      paths   = ["/hello"]
      service = google_compute_backend_service.cloud-run-global-lb-backend-service.id
    }
    name            = "cloud-run-global-lb-url-map-matcher"
    default_service = google_compute_backend_service.cloud-run-global-lb-backend-service.id
  }
  host_rule {
    hosts        = ["*"]
    path_matcher = "cloud-run-global-lb-url-map-matcher"
  }
}

#Create a target proxy and assign the URL map.
resource "google_compute_target_https_proxy" "cloud-run-global-lb-target-proxy" {
  name             = "cloud-run-global-lb-target-proxy"
  project          = var.project
  url_map          = google_compute_url_map.cloud-run-global-lb.id
  ssl_certificates = [google_compute_managed_ssl_certificate.global-sslcert.id]
}

#Create a global forwarding rule and assign the IP and target proxy.
resource "google_compute_global_forwarding_rule" "cloud-run-global-lb-forward" {
  name                  = "cloud-run-global-lb-forward"
  project               = var.project
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "443"
  ip_address            = var.global_ip_address
  target                = google_compute_target_https_proxy.cloud-run-global-lb-target-proxy.id
}

output "global_ip_address" {
  value       = var.global_ip_address
  description = "Reserved IP address for the global load balancing"
}