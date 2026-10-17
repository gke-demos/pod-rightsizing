# ADR-0003: Cooperative VPA + HPA Rightsizing Policy and Teardown Safety

- **Status:** Accepted
- **Date:** 2026-10-17

## Context

Historically, running `VerticalPodAutoscaler` and `HorizontalPodAutoscaler` simultaneously on CPU utilization caused scaling conflicts because standard VPA adjusts `requests.cpu` to match current per-Pod usage, which alters the denominator of HPA's `currentCPU / requestedCPU` utilization calculation.

In GKE `1.36.3-gke.1630000+`, adding `gke.io/autoscaling-hpa-rightsizing-mode: "gke-hpa-rightsizing-mode-policy"` to `VerticalPodAutoscaler.metadata.annotations` switches VPA to an HPA-aware rightsizing algorithm that evaluates aggregate historical demand alongside the HPA's `minReplicas`, `maxReplicas`, and target utilization.

## Decision

1. Annotate the `VerticalPodAutoscaler` with `gke.io/autoscaling-hpa-rightsizing-mode: "gke-hpa-rightsizing-mode-policy"` and set `spec.resourcePolicy.containerPolicies[]` with explicit `minAllowed` and `maxAllowed` boundaries.
2. For multi-container Pods (such as Pods with sidecars), configure the `HorizontalPodAutoscaler` to use `type: ContainerResource` targeting the primary application container (`containerResource.container`) so HPA and VPA evaluate the same container baseline.
3. Document and enforce teardown safety against the **Partial Teardown Footgun**: when disabling HPA rightsizing, operators must either delete the `VerticalPodAutoscaler` or set `spec.updatePolicy.updateMode: "Off"`—never remove only the `gke.io/autoscaling-hpa-rightsizing-mode` annotation while leaving `updateMode: "InPlaceOrRecreate"` active.

## Consequences

- HPA handles fast horizontal replica scaling during traffic spikes while VPA rightsizes per-replica CPU requests in-place without oscillation.
- Explicit teardown rules in `Makefile` and `TROUBLESHOOTING.md` prevent accidental reversion to conflicting standard VPA mode.
