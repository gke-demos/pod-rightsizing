# ADR-0005: Priority Preemption for Deferred In-Place Pod Resize and High Node Utilization

- **Status:** Accepted
- **Date:** 2026-10-21

## Context

When `VerticalPodAutoscaler` (`updateMode: "InPlaceOrRecreate"`) rightsizes an over-provisioned high-priority serving Pod downward in place, the node reclaims allocatable CPU and memory capacity. Platform teams want to bin-pack low-priority batch or scavenger Pods (`PriorityClass` with lower priority value) into that reclaimed node slack to push node request utilization above 90%.

However, packing the node creates a vertical scale-up deadlock when the high-priority serving Pod needs to scale back up in place. Because low-priority Pods now occupy the node's remaining allocatable CPU, `kubelet` cannot admit the higher CPU request and sets the Pod status condition `PodResizePending=True` (`reason: Deferred`) with a `ResizeDeferred` event. If the resize remains `Deferred` for more than 5 minutes under VPA `InPlaceOrRecreate`, the VPA Updater falls back to evicting and recreating the high-priority serving Pod (`EvictedByVPA`), defeating zero-restart vertical scaling.

In Kubernetes 1.37, KEP-5836 introduces `InPlacePodVerticalScalingSchedulerPreemption` (Alpha in 1.37). When enabled, `kube-scheduler` watches Pods with `PodResizePending: Deferred`, computes the resource delta (`Desired - Allocated`), and preempts the lowest-priority Pods on the same node so `kubelet` can immediately admit the in-place scale-up (`ResizeCompleted`, `restartCount: 0`). On Standard GKE 1.37 clusters (where Alpha feature gates are disabled by default), `kube-scheduler` does not automatically preempt running Pods for `Deferred` in-place resizes.

## Decision

1. Define two explicit `PriorityClass` objects in Demo 03 (`03-vpa-preemption-utilization`): `high-priority-serving` (`value: 1000000`) for latency-sensitive serving workloads and `low-priority-batch` (`value: 1000`, `preemptionPolicy: PreemptLowerPriority`) for opportunistic batch packers.
2. Co-locate `batch-scavenger` replicas on the same node as `serving-api` using `podAffinity` and short graceful termination (`terminationGracePeriodSeconds: 2`) so the demo deterministically packs the target node above 90% CPU request utilization after VPA rightsizes `serving-api` down in place.
3. Trigger an in-place vertical scale-up on `serving-api` (`kubectl patch pod --subresource=resize` / VPA target increase) so `kubelet` deterministically transitions the Pod into `PodResizePending=True (reason=Deferred)` (`Warning ResizeDeferred`).
4. Ensure Demo 03 works out of the box on both GKE 1.37 Alpha clusters (`InPlacePodVerticalScalingSchedulerPreemption=true`) and Standard GKE 1.37 clusters (`InPlacePodVerticalScalingSchedulerPreemption=false`) by including a KEP-5836-compatible priority preemption reconciler in the scale-up trigger that checks whether `kube-scheduler` native preemption resolved the `Deferred` condition and, on Standard clusters where the Alpha gate is disabled, evicts the minimum set of lower-priority `low-priority-batch` Pods on the same node required to satisfy `Desired - Allocated`.

## Consequences

- Operators can observe the complete lifecycle on any GKE 1.37 cluster: VPA in-place down-sizing (`InPlaceResizedByVPA`), >90% node bin-packing with `low-priority-batch` Pods, `PodResizePending: Deferred` (`ResizeDeferred`) when `high-priority-serving` scales up in place on the full node, priority-based preemption of lower-priority batch Pods, and zero-restart completion (`ResizeCompleted`, `RESTARTS: 0`).
- Documentation in `BLOG-03-VPA-PREEMPTION-UTILIZATION.md` and `TROUBLESHOOTING.md` clearly distinguishes between Alpha `kube-scheduler` preemption (`InPlacePodVerticalScalingSchedulerPreemption`), Standard GKE 1.37 behavior, and VPA's 5-minute `EvictedByVPA` fallback timer.
