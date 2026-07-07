locals {
  synthetic_check_files = fileset(path.module, "synthetic_checks/*.yaml")
  synthetic_checks = {
    for f in local.synthetic_check_files :
    trimsuffix(basename(f), ".yaml") => "${path.module}/${f}"
  }

  # `${frontend_url}` in each YAML is templated to the demo's public
  # frontend-proxy URL — the reserved static IP from frontend_public.tf.
  # Referencing the address here also creates an implicit dependency so
  # Terraform reserves the IP before creating the checks.
  synthetic_check_template_vars = {
    frontend_url = "http://${google_compute_address.frontend_public.address}"
  }
}

resource "dash0_synthetic_check" "this" {
  for_each = local.synthetic_checks

  dataset              = var.dash0_dataset
  synthetic_check_yaml = templatefile(each.value, local.synthetic_check_template_vars)
}
