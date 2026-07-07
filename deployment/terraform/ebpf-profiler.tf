# Node-local eBPF profiler DaemonSet, one pod per node, that ingests kernel
# and userland stack samples via BPF and forwards OTel profiles over OTLP/gRPC
# to the Dash0 operator's node-local collector Service. The operator's
# collector (see operator.profilingEnabled=true in main.tf) then relays the
# profiles to Dash0 with the standard resource enrichment applied to every
# other signal.
#
# GKE Autopilot caveat: this DaemonSet needs hostPID, hostPath mounts of
# /proc and /sys, and Linux capabilities (SYS_ADMIN, SYS_PTRACE, SYS_RESOURCE,
# SYSLOG). Autopilot's Warden admission webhook only permits those bits for
# workloads matching an installed WorkloadAllowlist. The dash0-operator's
# AllowlistSynchronizer covers Dash0/operator/* (the operator itself + the
# collectors it manages), which does NOT include this profiler image. If the
# cluster's Autopilot policy rejects these pods, the DaemonSet will report
# 0/N pods Ready — the operator side of profiling is still on, so the
# rejection is safe to observe before deciding to lift restrictions
# (e.g. moving this cluster to GKE Standard).

locals {
  # Pinned to the same image tag the operator's own e2e profiler chart uses
  # (see test-resources/ebpf-profiler in dash0hq/dash0-operator). Bump the
  # variable when the operator publishes a newer reference chart.
  ebpf_profiler_image = "otel/opentelemetry-collector-ebpf-profiler:${var.ebpf_profiler_image_tag}"

  # OTLP target is the operator's node-local collector Service, on the
  # standard gRPC OTLP port. Plaintext is fine — traffic never leaves the
  # cluster. The Service name is chart-generated from the Helm release name
  # (`dash0-operator`) — keep in sync if renaming that release.
  ebpf_profiler_collector_endpoint = "dash0-operator-opentelemetry-collector-service.${kubernetes_namespace.dash0_system.metadata[0].name}.svc.cluster.local:4317"

  ebpf_profiler_collector_config = <<-EOT
    receivers:
      profiling:

    exporters:
      otlp/collector:
        endpoint: ${local.ebpf_profiler_collector_endpoint}
        tls:
          insecure: true

    service:
      telemetry:
        logs:
          level: info
      pipelines:
        profiles:
          receivers: [profiling]
          exporters: [otlp/collector]
  EOT
}

resource "kubernetes_config_map" "ebpf_profiler_config" {
  metadata {
    name      = "ebpf-profiler-config"
    namespace = kubernetes_namespace.dash0_system.metadata[0].name
  }

  data = {
    "config.yaml" = local.ebpf_profiler_collector_config
  }
}

resource "kubernetes_daemon_set_v1" "ebpf_profiler" {
  # If GKE Autopilot's Warden rejects the profiler's privileged bits, the
  # rollout never completes and terraform apply would time out. Ship the
  # manifest and move on; the DaemonSet's status will surface the failure
  # (and it can't harm anything else in the cluster).
  wait_for_rollout = false

  metadata {
    name      = "ebpf-profiler"
    namespace = kubernetes_namespace.dash0_system.metadata[0].name
    labels = {
      "app" = "ebpf-profiler"
      # Opt out of the operator's own auto-instrumentation so the profiler
      # pods aren't wrapped in the LD_PRELOAD injector (moot with
      # instrumentWorkloads.mode=none, but future-proof against a template
      # change).
      "dash0.com/enable" = "false"
    }
  }

  spec {
    selector {
      match_labels = {
        app = "ebpf-profiler"
      }
    }

    template {
      metadata {
        labels = {
          "app"              = "ebpf-profiler"
          "dash0.com/enable" = "false"
        }
      }

      spec {
        host_pid = true

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.ebpf_profiler_config.metadata[0].name
          }
        }
        volume {
          name = "proc"
          host_path {
            path = "/proc"
          }
        }
        volume {
          name = "sys"
          host_path {
            path = "/sys"
          }
        }

        container {
          name  = "ebpf-profiler"
          image = local.ebpf_profiler_image
          args = [
            "--config=file:/etc/otelcol/config.yaml",
            "--feature-gates=service.profilesSupport",
          ]

          security_context {
            capabilities {
              add = ["SYS_ADMIN", "SYS_PTRACE", "SYS_RESOURCE", "SYSLOG"]
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/otelcol"
          }
          volume_mount {
            name       = "proc"
            mount_path = "/proc"
            read_only  = true
          }
          volume_mount {
            name       = "sys"
            mount_path = "/sys"
            read_only  = true
          }
        }
      }
    }
  }

  # The operator's collector Service must exist so the profiler's OTLP
  # exporter can resolve it on startup.
  depends_on = [helm_release.dash0_operator]
}
