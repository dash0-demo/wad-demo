output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_location" {
  value = google_container_cluster.primary.location
}

output "get_credentials_command" {
  description = "Run this locally to get a kubeconfig entry for the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${google_container_cluster.primary.location} --project ${var.project_id}"
}

output "frontend_public_url" {
  description = "Public HTTP URL of the demo's frontend-proxy. Use to validate the Dash0 Web SDK and to point Dash0 synthetics at."
  value       = "http://${google_compute_address.frontend_public.address}"
}
