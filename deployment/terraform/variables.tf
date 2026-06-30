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

variable "dash0_auth_token" {
  description = "Dash0 ingest auth token. Provide via TF_VAR_dash0_auth_token / GH Actions secret."
  type        = string
  sensitive   = true
}

variable "dash0_dataset" {
  description = "Dash0 dataset technical id receiving the telemetry."
  type        = string
  default     = "wad-demo"
}

variable "dash0_otlp_endpoint" {
  description = "Dash0 OTLP/HTTP ingress endpoint."
  type        = string
  default     = "https://ingress.eu-west-1.aws.dash0.com"
}
