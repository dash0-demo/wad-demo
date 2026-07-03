#!/usr/bin/env python3
"""Emit a JSON array of Dash0 {name, namespace} entries for workloads whose
pod template actually changed between two sets of Helm manifests.

Consumed by `.github/workflows/terraform.yml` after a `terraform apply` to
gate the `dash0-deploy-events` matrix — an unchanged service should not fan
out a deployment event.

Inputs are two directories of `helm get manifest <release> -n <ns>` output,
one file per release, e.g. `<dir>/otel-demo.yaml`, `<dir>/dash0-operator.yaml`.
A missing "before" file (fresh install) is treated as an empty manifest, so
every workload counts as changed on the first successful apply.

Change signal: sha256 of `.spec.template` (the pod template) — every Helm
value that would trigger a rollout ends up there. Kind ⊇ Deployment /
DaemonSet / StatefulSet.

Emitted `name` is the workload's `app.kubernetes.io/component` label (falls
back to `metadata.name` if unset). Emitted `namespace` maps the k8s
namespace to the Dash0 service.namespace convention used elsewhere in the
demo — otel-demo → "otel-demo", dash0-system → "dash0-operator".
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import yaml  # PyYAML — installed via pip in the workflow.

WORKLOAD_KINDS = {"Deployment", "DaemonSet", "StatefulSet"}

# k8s namespace → Dash0 service.namespace value on emitted events.
# Runtime telemetry from these pods already carries these service.namespace
# values (see values.yaml OTEL_RESOURCE_ATTRIBUTES and the operator's chart
# defaults), so events must match to correlate on the same service.
DASH0_NAMESPACE_BY_K8S_NS = {
    "otel-demo": "otel-demo",
    "dash0-system": "dash0-operator",
}


def load_workload_hashes(path: Path) -> dict[tuple[str, str], tuple[str, str]]:
    """Return {(k8s_namespace, workload_name): (component_label, template_hash)}.

    A missing file yields an empty dict; the caller treats every workload
    in the "after" set as new.
    """
    if not path.exists():
        return {}
    with path.open() as f:
        docs = list(yaml.safe_load_all(f))
    out: dict[tuple[str, str], tuple[str, str]] = {}
    for doc in docs:
        if not doc or doc.get("kind") not in WORKLOAD_KINDS:
            continue
        md = doc.get("metadata") or {}
        ns = md.get("namespace") or ""
        name = md.get("name") or ""
        labels = md.get("labels") or {}
        component = labels.get("app.kubernetes.io/component") or name
        template = (doc.get("spec") or {}).get("template") or {}
        digest = hashlib.sha256(
            json.dumps(template, sort_keys=True, default=str).encode()
        ).hexdigest()
        out[(ns, name)] = (component, digest)
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"usage: {sys.argv[0]} <before-dir> <after-dir>",
            file=sys.stderr,
        )
        return 2
    before_dir = Path(sys.argv[1])
    after_dir = Path(sys.argv[2])

    changed: list[dict[str, str]] = []
    for after_file in sorted(after_dir.glob("*.yaml")):
        after = load_workload_hashes(after_file)
        before = load_workload_hashes(before_dir / after_file.name)
        for (ns, name), (component, digest) in after.items():
            before_hash = before.get((ns, name), (None, None))[1]
            if before_hash == digest:
                continue
            dash0_ns = DASH0_NAMESPACE_BY_K8S_NS.get(ns, ns)
            changed.append({"name": component, "namespace": dash0_ns})

    # Dedupe (Helm can emit the same component name in multiple workloads;
    # a change in any of them should surface as one event, not several).
    seen: set[tuple[str, str]] = set()
    unique: list[dict[str, str]] = []
    for entry in changed:
        key = (entry["name"], entry["namespace"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(entry)

    print(json.dumps(unique))
    return 0


if __name__ == "__main__":
    sys.exit(main())
