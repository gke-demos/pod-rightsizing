# ADR-0004: Admission-Only Boost Semantics on In-Place Container Restart

- **Status:** Accepted
- **Date:** 2026-10-17

## Context

**CPU Startup Boost** is applied by the GKE VPA mutating admission webhook (`gke-vpa-webhook-config`) when a `Pod` object is first created in `kube-apiserver` (injecting `vpaCPUStartupBoost/<container-name>`, `vpaObservedContainers`, and `vpaUpdates`). Once the Pod reaches `Ready`, the VPA Updater performs **In-Place Unboost**, restoring the Pod's `spec.containers[].resources` to the baseline CPU request and limit and removing the `vpaCPUStartupBoost/<container-name>` annotation.

If a container subsequently crashes (`Error` or `OOMKilled`) while the `Pod` object remains scheduled on the node, `kubelet` restarts the container in-place (`restartCount` increments) without creating a new `Pod` object in `kube-apiserver`.

## Decision

Document and verify in `TROUBLESHOOTING.md` that **CPU Startup Boost** applies strictly to initial Pod creation (including new Pods created by Deployment rollouts or HPA scale-out events) and does not re-trigger on in-place `kubelet` container restarts after **In-Place Unboost** has completed.

## Consequences

- Platform engineers understand why crash-looping containers inside an existing Pod initialize at steady-state CPU requests after their first `Ready` transition, whereas newly scaled-out HPA replicas receive the full admission boost.
