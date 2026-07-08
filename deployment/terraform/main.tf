resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region

  # Standard (not Autopilot). Autopilot's Warden admission webhook forbids the
  # privileged bits the eBPF profiler DaemonSet needs — hostPID, hostPath on
  # `/proc` + `/sys`, and Linux capabilities SYS_ADMIN/SYS_RESOURCE/SYSLOG. On
  # Standard we control node pools ourselves and none of those constraints
  # apply, so the profiler pods can run. Switching between Autopilot and
  # Standard is not an in-place operation — Terraform will destroy and
  # recreate the cluster (and every workload in it) when this changes.

  # Manage node pools as separate resources so pool changes don't trigger a
  # full cluster replacement. GKE always tries to create a default pool when
  # the cluster is created; setting initial_node_count=1 keeps that transient
  # pool small, and remove_default_node_pool=true tears it down immediately
  # after the cluster is up.
  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {}

  deletion_protection = false
}

# Single node pool sized for the demo: Dash0 operator + its DaemonSet and
# Deployment collectors, ~15 otel-demo microservices, the load generator
# (50 Locust users), and the eBPF profiler DaemonSet. e2-standard-4 gives
# 4 vCPU / 16 GiB per node. The cluster is regional, so `node_count` is
# per-zone — with three zones in europe-west1 the default (1) yields three
# nodes, enough headroom and enough spread for the profiler to exercise
# multi-node scenarios.
resource "google_container_node_pool" "primary" {
  name       = "primary"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = var.gke_node_count

  node_config {
    machine_type = var.gke_machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"

    # Least-privilege service account scopes for a demo; nothing here reads
    # from GCP APIs beyond the standard container runtime needs.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
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

  # Turn on profile ingestion in the operator's collectors. The eBPF profiler
  # DaemonSet (see ebpf-profiler.tf) exports profiles via OTLP/gRPC to the
  # operator's node-local collector, which forwards them to Dash0.
  set {
    name  = "operator.profilingEnabled"
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

# Dash0 auth token used by the frontend-proxy's `/_dash0/*` reverse proxy to
# add `Authorization: Bearer <token>` to OTLP HTTP requests before forwarding
# them upstream to Dash0's ingest. Must be a token scoped to the wad-demo
# dataset with Ingesting-only permission — anyone who finds the same-origin
# proxy path can post telemetry against this token, same posture as an
# ingest-only browser token.
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

# Patched locustfile that fixes the Playwright tasks. Upstream references
# `self.tracer` inside `WebsiteBrowserUser`'s async @task methods; under the
# locust_plugins Playwright user (gevent + asyncio interop) those tasks run
# where `self` doesn't carry the __init__-assigned attribute, so every task
# raises AttributeError swallowed by the surrounding try/except. Result:
# Locust reports 10 browser users spawned but no HTTP request ever reaches
# frontend-proxy. This file swaps to a module-level `tracer`.
#
# `values.yaml` overrides `components.load-generator.additionalVolumes` +
# `additionalVolumeMounts` so the pod mounts this ConfigMap over the image's
# baked-in `/usr/src/app/locustfile.py`.
resource "kubernetes_config_map" "load_generator_locustfile" {
  metadata {
    name      = "load-generator-locustfile-override"
    namespace = kubernetes_namespace.otel_demo.metadata[0].name
  }

  data = {
    "locustfile.py" = file("${path.module}/loadgen/locustfile.py")
    # Overlays the upstream image's baked-in people.json (used by
    # WebsiteUser checkout tasks and now by WebsiteBrowserUser's
    # seed_person to seed a persistent identity for the Web SDK).
    # Extends the upstream 9-person set with EU/AS/SA entries so the
    # Web Monitoring world map isn't a single US/DE blob.
    "people.json" = file("${path.module}/loadgen/people.json")
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
            # Host-only (no scheme, no port) — used by Envoy as both the
            # upstream socket_address and the TLS SNI for the same-origin
            # `/_dash0/*` proxy route. Derived from the OTLP HTTP endpoint
            # so a tenant override in one place flows to both.
            name  = "DASH0_WEB_SDK_UPSTREAM_HOST"
            value = regex("^https?://([^/]+)", var.dash0_otlp_http_endpoint)[0]
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
  # flagd config override must exist before the flagd pod schedules or its
  # init container will fail. The envoy config override + web-sdk token
  # secret must exist before the frontend-proxy pod starts.
  depends_on = [
    helm_release.dash0_operator,
    kubernetes_config_map.flagd_config_override,
    kubernetes_config_map.frontend_proxy_envoy,
    kubernetes_secret.dash0_web_sdk,
  ]
}
