# ADR-0001: Mandatory `readinessProbe` and `durationSeconds: 0` for HPA-Safe CPU Startup Boost

- **Status:** Accepted
- **Date:** 2026-10-17

## Context

When a workload uses both **CPU Startup Boost** (`spec.startupBoost.cpu` on `VerticalPodAutoscaler`) and a CPU-based `HorizontalPodAutoscaler` (`autoscaling/v2`), the Pod consumes elevated CPU (for example, `1000m` instead of `250m` baseline) during its cold-start initialization phase.

In Kubernetes, HPA ignores CPU usage from unready Pods during their initialization window (`--horizontal-pod-autoscaler-initial-readiness-delay`). However, as soon as a Pod transitions to `Ready = True`, HPA includes its CPU utilization in the replica scaling calculation. If a Pod either:
1. Lacks a `readinessProbe` (so it becomes `Ready` immediately while initialization is still burning boosted CPU), or
2. Sets `startupBoost.cpu.durationSeconds` to a positive value so the boost persists after `Ready`,

then the **HPA Startup Spillover Trap** occurs: HPA observes high CPU utilization on the newly `Ready` Pod and triggers cascading, unnecessary horizontal scale-out events.

## Decision

1. Every workload using **CPU Startup Boost** alongside HPA MUST define a `readinessProbe` (`/readyz`) that returns HTTP `200 OK` only after the CPU-intensive initialization task has completed.
2. When **CPU Startup Boost** is paired with HPA, `spec.startupBoost.cpu.durationSeconds` MUST be set to `0` so the boost is eligible for **In-Place Unboost** immediately upon reaching `Ready`.

## Consequences

- Initialization finishes 3–4x faster under boosted CPU while the Pod is still `NotReady`, invisible to HPA's scale-out trigger.
- As soon as initialization completes and `/readyz` succeeds, the Pod's CPU consumption drops to steady-state idle levels and the VPA Updater resizes the container back to its baseline request in-place (`reason=InPlaceResizedByVPA`).
