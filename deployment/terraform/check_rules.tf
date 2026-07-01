locals {
  check_rule_files = fileset(path.module, "check_rules/*.yaml")
  check_rules = {
    for f in local.check_rule_files :
    trimsuffix(basename(f), ".yaml") => "${path.module}/${f}"
  }
}

resource "dash0_check_rule" "this" {
  for_each = local.check_rules

  dataset         = var.dash0_dataset
  check_rule_yaml = file(each.value)
}
