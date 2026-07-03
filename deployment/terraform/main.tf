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

# Public (browser-exposed) Dash0 auth token, mounted into the frontend-proxy
# pod via an env var and inlined at container start by envsubst into the Lua
# HTTP filter's source. MUST be a token scoped to the wad-demo dataset with
# Ingesting-only permission — it will be visible to anyone who views the site.
resource "kubernetes_secret" "dash0_web_sdk" {
  metadata {
    name      = "dash0-web-sdk-token"
    namespace = kubernetes_namespace.otel_demo.metadata[0].name
  }

  data = {
    token = var.dash0_web_sdk_auth_token
  }
}

# Overrides the envoy.tmpl.yaml baked into the demo's frontend-proxy image.
# The fork adds a Lua HTTP filter that injects the Dash0 Web SDK <script> tag
# into text/html responses. When bumping otel_demo_chart_version, re-sync the
# base config against the matching upstream tag and reapply the Lua filter.
resource "kubernetes_config_map" "frontend_proxy_envoy" {
  metadata {
    name      = "frontend-proxy-envoy-override"
    namespace = kubernetes_namespace.otel_demo.metadata[0].name
  }

  data = {
    "envoy.tmpl.yaml" = file("${path.module}/frontend-proxy/envoy.tmpl.yaml")
  }
}

locals {
  # Wire the Dash0 Web SDK into the demo's frontend-proxy Envoy: mount our
  # forked envoy.tmpl.yaml over the image's baked-in one, and expose the
  # Web-SDK-specific config (endpoint, public token, service version, VCS
  # attributes) as pod env vars. envsubst inlines them into the Lua HTTP
  # filter's source at container start.
  otel_demo_values_overrides = yamlencode({
    components = {
      "frontend-proxy" = {
        envOverrides = [
          {
            name  = "DASH0_WEB_SDK_ENDPOINT_URL"
            value = var.dash0_otlp_http_endpoint
          },
          {
            name = "DASH0_WEB_SDK_AUTH_TOKEN"
            valueFrom = {
              secretKeyRef = {
                name = kubernetes_secret.dash0_web_sdk.metadata[0].name
                key  = "token"
              }
            }
          },
          {
            name  = "DASH0_WEB_SDK_SERVICE_VERSION"
            value = var.otel_demo_chart_version
          },
          {
            name  = "DASH0_WEB_SDK_SERVICE_NAMESPACE"
            value = kubernetes_namespace.otel_demo.metadata[0].name
          },
          {
            name  = "DASH0_WEB_SDK_VCS_REPO_URL"
            value = var.github_repo_url
          },
          {
            name  = "DASH0_WEB_SDK_VCS_HEAD_SHA"
            value = data.external.git_head.result.sha
          },
        ]
        additionalVolumes = [
          {
            name = "envoy-config-override"
            configMap = {
              name = kubernetes_config_map.frontend_proxy_envoy.metadata[0].name
            }
          },
        ]
        additionalVolumeMounts = [
          {
            name      = "envoy-config-override"
            mountPath = "/home/envoy/envoy.tmpl.yaml"
            subPath   = "envoy.tmpl.yaml"
          },
        ]
      }
    }
  })
}

resource "helm_release" "otel_demo" {
  name       = "otel-demo"
  namespace  = kubernetes_namespace.otel_demo.metadata[0].name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-demo"
  version    = var.otel_demo_chart_version

  values = [
    file("${path.module}/../helm/values.yaml"),
    local.otel_demo_values_overrides,
  ]

  timeout = 900

  # The operator must be running first so its mutating webhook is available
  # when the demo pods are created (it injects k8s resource attributes). The
  # envoy config override + web-sdk token secret must exist before the
  # frontend-proxy pod starts.
  depends_on = [
    helm_release.dash0_operator,
    kubernetes_config_map.frontend_proxy_envoy,
    kubernetes_secret.dash0_web_sdk,
  ]
}
