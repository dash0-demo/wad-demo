variable "project_id" {
  description = "GCP project hosting the GKE cluster."
  type        = string
}

variable "region" {
  description = "GCP region for the GKE Autopilot cluster."
  type        = string
  default     = "europe-west1"
}

variable "cluster_name" {
  description = "GKE cluster name."
  type        = string
  default     = "wad-demo"
}

variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR, STABLE."
  type        = string
  default     = "REGULAR"
}

variable "otel_demo_chart_version" {
  description = "Version of the open-telemetry/opentelemetry-demo Helm chart."
  type        = string
  default     = "0.40.9"
}

variable "dash0_operator_chart_version" {
  description = "Version of the dash0-operator/dash0-operator Helm chart. Leave empty to use the latest published."
  type        = string
  default     = ""
}

variable "dash0_auth_token" {
  description = "Dash0 ingest auth token used by the operator's collectors. Provide via TF_VAR_dash0_auth_token / GH Actions secret."
  type        = string
  sensitive   = true
}

variable "dash0_api_token" {
  description = "Dash0 management API token used by the dash0 Terraform provider (needs write permissions on check rules, dashboards, etc.). Provide via TF_VAR_dash0_api_token / GH Actions secret."
  type        = string
  sensitive   = true
}

variable "dash0_dataset" {
  description = "Dash0 dataset technical id receiving the telemetry."
  type        = string
  default     = "wad-demo"
}

variable "dash0_otlp_grpc_endpoint" {
  description = "Dash0 OTLP/gRPC ingress endpoint used by the operator's collectors. Format: host:port (no scheme)."
  type        = string
  default     = "ingress.eu-west-1.aws.dash0.com:4317"
}

variable "dash0_api_endpoint" {
  description = "Dash0 API endpoint used by the operator for resource synchronization (dashboards, views, etc.)."
  type        = string
  default     = "https://api.eu-west-1.aws.dash0.com"
}

variable "github_repo_url" {
  description = "Full HTTPS URL of the GitHub repo backing this deployment. Injected on all telemetry as vcs.repository.url.full so Agent0 can locate the code and open PRs."
  type        = string
  default     = "https://github.com/dash0-demo/wad-demo"
}
