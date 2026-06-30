resource "google_container_cluster" "primary" {
  name             = var.cluster_name
  location         = var.region
  enable_autopilot = true

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {}

  deletion_protection = false
}

resource "kubernetes_namespace" "otel_demo" {
  metadata {
    name = "otel-demo"
  }

  depends_on = [google_container_cluster.primary]
}

resource "kubernetes_secret" "dash0_auth" {
  metadata {
    name      = "dash0-auth"
    namespace = kubernetes_namespace.otel_demo.metadata[0].name
  }

  data = {
    token    = var.dash0_auth_token
    dataset  = var.dash0_dataset
    endpoint = var.dash0_otlp_endpoint
  }
}

resource "helm_release" "otel_demo" {
  name       = "otel-demo"
  namespace  = kubernetes_namespace.otel_demo.metadata[0].name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-demo"
  version    = var.otel_demo_chart_version

  values = [file("${path.module}/../helm/values.yaml")]

  timeout = 900

  depends_on = [kubernetes_secret.dash0_auth]
}
