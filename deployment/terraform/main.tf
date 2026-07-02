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

data "external" "git_head" {
  # Read the currently checked-out commit so it can be tagged onto every
  # telemetry signal via vcs.ref.head.revision. Works locally and in CI
  # (actions/checkout@v4 leaves HEAD pointed at the deployed commit).
  program     = ["sh", "-c", "printf '{\"sha\":\"%s\"}' \"$(git rev-parse HEAD)\""]
  working_dir = path.module
}

locals {
  # OTTL statements injected via the operator's monitoring template. They set
  # the OTel VCS resource attributes on every span/metric/log so Agent0 can
  # locate this repo, know which commit was deployed, and open PRs against it.
  vcs_ottl_statements = [
    "set(attributes[\"vcs.repository.url.full\"], \"${var.github_repo_url}\")",
    "set(attributes[\"vcs.ref.head.revision\"], \"${data.external.git_head.result.sha}\")",
    "set(attributes[\"vcs.provider.name\"], \"github\")",
  ]

  dash0_operator_values = yamlencode({
    operator = {
      # The demo apps already carry their own OpenTelemetry SDKs, so keep the
      # default monitoring template's LD_PRELOAD injector off. Also inject the
      # VCS attributes via the built-in transform processor.
      monitoringTemplate = {
        spec = {
          instrumentWorkloads = { mode = "none" }
          transform = {
            error_mode = "ignore"
            trace_statements = [{
              context    = "resource"
              statements = local.vcs_ottl_statements
            }]
            metric_statements = [{
              context    = "resource"
              statements = local.vcs_ottl_statements
            }]
            log_statements = [{
              context    = "resource"
              statements = local.vcs_ottl_statements
            }]
          }
        }
      }
    }
  })
}

resource "helm_release" "dash0_operator" {
  name       = "dash0-operator"
  namespace  = kubernetes_namespace.dash0_system.metadata[0].name
  repository = "https://dash0hq.github.io/dash0-operator"
  chart      = "dash0-operator"
  version    = var.dash0_operator_chart_version != "" ? var.dash0_operator_chart_version : null

  timeout = 600

  values = [local.dash0_operator_values]

  # GKE Autopilot allow-list synchronizer: lets the operator's pods carry
  # the custom node-affinity keys (dash0.com/enable) and other privileged
  # bits that Autopilot's Warden would otherwise reject.
  set {
    name  = "operator.gke.autopilot.enabled"
    value = "true"
  }

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
  # out.
  set {
    name  = "operator.autoMonitorNamespaces.enabled"
    value = "true"
  }

  depends_on = [kubernetes_secret.dash0_authorization]
}

resource "kubernetes_namespace" "otel_demo" {
  metadata {
    name = "otel-demo"
  }

  depends_on = [google_container_cluster.primary]
}

# Custom flagd config that replaces the ConfigMap the chart bakes from its
# own `flagd/demo.flagd.json`. Used to bake `productCatalogFailure=on` (and
# any other flag defaults we want to survive flagd pod restarts, since the
# chart's default config is copied into an emptyDir at init and any UI toggle
# is lost on restart).
#
# `values.yaml` overrides `components.flagd.additionalVolumes` so the flagd
# pod mounts THIS ConfigMap under `config-ro` instead of the chart-generated
# `flagd-config`.
resource "kubernetes_config_map" "flagd_config_override" {
  metadata {
    name      = "flagd-config-override"
    namespace = kubernetes_namespace.otel_demo.metadata[0].name
  }

  data = {
    "demo.flagd.json" = file("${path.module}/flagd/demo.flagd.json")
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

  # The operator must be running first so its mutating webhook is available
  # when the demo pods are created (it injects k8s resource attributes). The
  # flagd config override must exist before the flagd pod schedules or the
  # init container will fail.
  depends_on = [
    helm_release.dash0_operator,
    kubernetes_config_map.flagd_config_override,
  ]
}
