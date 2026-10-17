# ADR-0002: Preserving QoS Class via `RequestsAndLimits` for Zero-Restart In-Place Unboost

- **Status:** Accepted
- **Date:** 2026-10-17

## Context

**In-Place Unboost** relies on Kubernetes **In-Place Pod Resize (IPPR)** (`spec.updatePolicy.updateMode: "InPlaceOrRecreate"`) to reduce a container's CPU allocation from its boosted admission value back to its baseline value without restarting the container (`restartCount: 0`).

However, Kubernetes imposes an invariant that a Pod's Quality of Service (QoS) class (`Guaranteed`, `Burstable`, or `BestEffort`) is immutable after Pod creation. Furthermore, if a container defines a CPU limit (`limits.cpu: 250m`) equal to its request (`requests.cpu: 250m`), boosting only `requests.cpu` without boosting `limits.cpu` would either violate `requests.cpu <= limits.cpu` or leave the container throttled by `limits.cpu: 250m` during startup.

## Decision

1. Use VPA's default `controlledValues: RequestsAndLimits` behavior on boosted containers so that GKE boosts both `requests.cpu` and `limits.cpu` proportionally (maintaining the original request-to-limit ratio and preserving the Pod's QoS class).
2. Ensure containers do not set `resizePolicy` for `cpu` to `RestartContainer` (leaving the default `NotRequired`), so the VPA Updater actuates both **In-Place Unboost** and steady-state **Cooperative VPA + HPA Rightsizing** via cgroup updates with zero container restarts.

## Consequences

- Workloads defining both `requests.cpu` and `limits.cpu` actually receive the higher CFS bandwidth quota (`cpu.max`) during cold start rather than remaining capped by a static `limits.cpu`.
- QoS class remains invariant across admission boost, **In-Place Unboost**, and ongoing rightsizing, preventing fallback to disruptive Pod eviction (`Recreate`).
