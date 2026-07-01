locals {
  check_rules = {
    product_catalog_latency = {
      alert              = "product-catalog: High p95 Latency"
      summary            = "p95 latency on product-catalog is elevated"
      description        = "The 95th-percentile span duration for product-catalog has exceeded the threshold over a 5-minute window. Degraded fires at 6s (normal peak is ~4.65s), Critical fires at 10s (~2x normal). Investigate slow operations, database queries, or upstream dependency latency."
      expression         = "max by (service_namespace, service_name) (histogram_quantile(0.95, sum by(le) (rate({otel_metric_name=\"dash0.spans.duration\", service_name=\"product-catalog\"}[5m])))) > $__threshold"
      for                = "2m0s"
      threshold_degraded = "0.5"
      threshold_critical = "1"
    }
    product_catalog_errors = {
      alert              = "product-catalog: High Error Rate"
      summary            = "Error rate on product-catalog is elevated"
      description        = "The percentage of error spans from product-catalog has exceeded the threshold over a 5-minute window. Degraded fires at 0.1% (about 4x the normal peak), Critical fires at 0.5%. Investigate recent deployments, downstream dependencies, or request patterns."
      expression         = "100 * sum by (service_namespace, service_name) (rate({otel_metric_name=\"dash0.spans\", otel_span_status_code=\"ERROR\", service_name=\"product-catalog\"}[5m])) / sum by (service_namespace, service_name) (rate({otel_metric_name=\"dash0.spans\", service_name=\"product-catalog\"}[5m])) > $__threshold"
      for                = "2m0s"
      threshold_degraded = "0.1"
      threshold_critical = "0.5"
    }
  }
}

resource "dash0_check_rule" "this" {
  for_each = local.check_rules

  dataset = var.dash0_dataset

  check_rule_yaml = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PrometheusRule
    metadata:
      name: ${each.key}
    spec:
      groups:
        - name: Alerting
          interval: 1m0s
          rules:
            - alert: ${each.value.alert}
              expr: ${each.value.expression}
              for: ${each.value.for}
              keep_firing_for: 0s
              annotations:
                summary: ${jsonencode(each.value.summary)}
                description: ${jsonencode(each.value.description)}
                dash0-threshold-degraded: ${jsonencode(each.value.threshold_degraded)}
                dash0-threshold-critical: ${jsonencode(each.value.threshold_critical)}
                dash0-enabled: "true"
              labels: {}
  YAML
}
