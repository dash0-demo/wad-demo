# Public HTTP exposure of the demo's frontend-proxy Envoy, so a real browser
# can hit the site (Web SDK / Dash0 synthetics). We do NOT flip the chart's
# ClusterIP Service to LoadBalancer because the chart doesn't expose
# `spec.loadBalancerIP` — instead we stand up a sibling Service that selects
# the same frontend-proxy pods and pins to a Terraform-reserved static IP.
#
# HTTP only for now (browsers will show "Not Secure"). Adding HTTPS is a
# separate change: it needs a domain + a GKE Ingress with a Google-managed
# certificate; today the demo has neither.

resource "google_compute_address" "frontend_public" {
  name         = "wad-demo-frontend"
  region       = var.region
  address_type = "EXTERNAL"
  description  = "Static IP for the wad-demo frontend-proxy LoadBalancer."
}

resource "kubernetes_service_v1" "frontend_proxy_external" {
  metadata {
    name      = "frontend-proxy-external"
    namespace = kubernetes_namespace.otel_demo.metadata[0].name
    labels = {
      "app.kubernetes.io/component" = "frontend-proxy"
      "app.kubernetes.io/part-of"   = "opentelemetry-demo"
    }
  }

  spec {
    type             = "LoadBalancer"
    load_balancer_ip = google_compute_address.frontend_public.address

    # The chart labels its frontend-proxy pods with opentelemetry.io/name.
    # Keeping this selector minimal (single label) is enough — the pods for
    # other components carry different values here.
    selector = {
      "opentelemetry.io/name" = "frontend-proxy"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }

  # A LB requires the underlying pods to exist so the target pool has
  # something to serve traffic. The helm release brings the pods up.
  depends_on = [helm_release.otel_demo]
}