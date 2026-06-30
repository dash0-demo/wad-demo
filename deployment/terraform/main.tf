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

# Namespace hosting the Dash0 operator and the auth secret it consumes.
resource "kubernetes_namespace" "dash0_system" {
  metadata {
    name = "dash0-system"
  }

  depends_on = [google_container_cluster.primary]
}

resource "kubernetes_secret" "dash0_authorization" {
  metadata {
    name      = "dash0-authorization-secret"
    namespace = kubernetes_namespace.dash0_system.metadata[0].name
  }

  data = {
    token = var.dash0_auth_token
  }
}

resource "helm_release" "dash0_operator" {
  name       = "dash0-operator"
  namespace  = kubernetes_namespace.dash0_system.metadata[0].name
  repository = "https://dash0hq.github.io/dash0-operator"
  chart      = "dash0-operator"
  version    = var.dash0_operator_chart_version != "" ? var.dash0_operator_chart_version : null

  timeout = 600

  set {
    name  = "operator.dash0Export.enabled"
    value = "true"
  }
  set {
    name  = "operator.dash0Export.endpoint"
    value = var.dash0_otlp_grpc_endpoint
  }
  set {
    name  = "operator.dash0Export.apiEndpoint"
    value = var.dash0_api_endpoint
  }
  set {
    name  = "operator.dash0Export.dataset"
    value = var.dash0_dataset
  }
  set {
    name  = "operator.dash0Export.secretRef.name"
    value = kubernetes_secret.dash0_authorization.metadata[0].name
  }
  set {
    name  = "operator.dash0Export.secretRef.key"
    value = "token"
  }

  # Auto-monitor every non-system namespace. The default label selector
  # ("dash0.com/enable!=false") matches everything that isn't explicitly opted
  # out. The demo apps already carry their own OpenTelemetry SDKs, so we set
  # the default monitoring template's instrumentWorkloads.mode to "none" to
  # skip the operator's LD_PRELOAD auto-instrumentation and avoid double
  # instrumentation. Logs, k8s events, and cluster metrics still flow.
  set {
    name  = "operator.autoMonitorNamespaces.enabled"
    value = "true"
  }
  set {
    # The monitoring template is a top-level operator setting (the chart
    # rejects placing it under autoMonitorNamespaces).
    name  = "operator.monitoringTemplate.spec.instrumentWorkloads.mode"
    value = "none"
  }

  depends_on = [kubernetes_secret.dash0_authorization]
}

resource "kubernetes_namespace" "otel_demo" {
  metadata {
    name = "otel-demo"
  }

  depends_on = [google_container_cluster.primary]
}

resource "helm_release" "otel_demo" {
  name       = "otel-demo"
  namespace  = kubernetes_namespace.otel_demo.metadata[0].name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-demo"
  version    = var.otel_demo_chart_version

  values = [file("${path.module}/../helm/values.yaml")]

  timeout = 900

  # The operator must be running first so its mutating webhook is available
  # when the demo pods are created (it injects k8s resource attributes).
  depends_on = [helm_release.dash0_operator]
}
