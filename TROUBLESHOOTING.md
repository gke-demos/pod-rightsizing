# Troubleshooting and operational field guide

Production lessons and debugging commands for **Zero-Restart Pod Rightsizing** on GKE 1.37+ (`VPA CPU Startup Boost`, `InPlaceOrRecreate`, `Cooperative VPA + HPA Rightsizing`, and `KCP_VPA` decision logs).

## 1. HPA startup spillover trap: why `readinessProbe` and `durationSeconds: 0` are required together

### Symptom

When a workload uses both **CPU Startup Boost** (`spec.startupBoost.cpu`) and a CPU-based `HorizontalPodAutoscaler`, HPA scales out extra replicas right after a rollout or cold start even though incoming request traffic is low.

### Root cause

The Kubernetes HPA controller includes a Pod's CPU usage in its `averageUtilization` calculation as soon as the Pod's `Ready` condition becomes `True`. If a container lacks a `readinessProbe` (so it becomes `Ready` immediately upon starting while still running heavy startup initialization) or if `startupBoost.cpu.durationSeconds` is greater than `0`, the elevated startup CPU usage spills into the `Ready` window and inflates HPA's utilization metric.

### Fix and verification

1. Define a `readinessProbe` on the container that returns success only after initialization (JIT compilation, cache warming, model loading) finishes.
2. Set `spec.startupBoost.cpu.durationSeconds: 0` on the `VerticalPodAutoscaler` so the VPA Updater triggers **In-Place Unboost** on its first evaluation cycle after the Pod reaches `Ready`:

```bash
kubectl -n pod-rightsizing-hpa get vpa rightsized-api-vpa \
  -o jsonpath='{.spec.startupBoost.cpu}{"\n"}'
```

See [ADR-0001](docs/adr/0001-readiness-probe-and-zero-duration-for-hpa-safe-startup-boost.md).

## 2. Preserving `Burstable` QoS so In-Place Unboost never recreates the Pod

### Symptom

Instead of resizing CPU in place (`RESTARTS: 0`), a Pod managed by `updateMode: "InPlaceOrRecreate"` is evicted and recreated when VPA applies a recommendation or unboosts startup CPU.

### Root cause

Kubernetes **In-Place Pod Resize (IPPR)** cannot change a Pod's Quality of Service (`qosClass`, such as transitioning between `Burstable` and `Guaranteed`). If a resource update would alter `status.qosClass`, `InPlaceOrRecreate` falls back to `Recreate` mode and evicts the Pod.

### Fix and verification

Specify both `requests` and `limits` (`Burstable` QoS when memory or CPU bounds differ, or preserved ratio under `controlledValues: RequestsAndLimits`) on the container spec and configure `controlledValues: RequestsAndLimits` on the VPA container policy.

Verify that the Pod's `qosClass` and `restartCount` remain unchanged across **In-Place Unboost**:

```bash
kubectl -n pod-rightsizing get pods -l demo=startup-boost \
  -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass,REQ_CPU:.spec.containers[0].resources.requests.cpu,LIM_CPU:.spec.containers[0].resources.limits.cpu,RESTARTS:.status.containerStatuses[0].restartCount
```

See [ADR-0002](docs/adr/0002-requests-and-limits-qos-preservation-for-in-place-unboost.md).

## 3. Partial teardown footgun when disabling Cooperative VPA + HPA Rightsizing

### Symptom

After removing the `gke.io/autoscaling-hpa-rightsizing-mode: "gke-hpa-rightsizing-mode-policy"` annotation from an active `VerticalPodAutoscaler`, the workload experiences replica count oscillation and competing vertical/horizontal resizes.

### Root cause

Removing only the `gke.io/autoscaling-hpa-rightsizing-mode` annotation while leaving `spec.updatePolicy.updateMode` set to `"InPlaceOrRecreate"` or `"Recreate"` reverts the VPA to standard non-cooperative mode. Standard VPA and CPU-based HPA then fight over the same CPU utilization signal.

### Fix and verification

To disable **Cooperative VPA + HPA Rightsizing** safely, either delete the `VerticalPodAutoscaler` resource or set `spec.updatePolicy.updateMode: "Off"` before removing the annotation:

```bash
kubectl -n pod-rightsizing-hpa patch vpa rightsized-api-vpa \
  --type=merge -p '{"spec":{"updatePolicy":{"updateMode":"Off"}}}'
```

See [ADR-0003](docs/adr/0003-cooperative-vpa-hpa-rightsizing-policy-and-teardown-safety.md).

## 4. Admission-only boost semantics and `vpaCPUStartupBoost` annotation casing

### Symptom

1. You apply a `VerticalPodAutoscaler` with `startupBoost` *after* the `Deployment` is already running, or a container crashes and restarts in place (`RESTARTS: 1`), and the container does not receive the startup CPU boost.
2. You look for `metadata.annotations["vpaCpuStartupBoost/<container>"]` with lowercase `pu` and do not find it on GKE 1.37.

### Root cause

1. **CPU Startup Boost** is injected by the GKE VPA mutating admission webhook (`gke-vpa-webhook-config`) only when a `Pod` object is first created in `kube-apiserver`. Once the Pod reaches `Ready` and **In-Place Unboost** completes (`reason=InPlaceResizedByVPA`), the boost annotation is removed. In-place container restarts handled by `kubelet` do not recreate the `Pod` object and therefore do not re-trigger the admission webhook.
2. On GKE 1.37 (`gke-vpa-webhook-config`), the admission webhook writes the annotation key with uppercase `CPU`: `vpaCPUStartupBoost/<container-name>` (alongside `vpaObservedContainers` and `vpaUpdates`).

### Fix and verification

Always create or update the `VerticalPodAutoscaler` before creating or rolling out the target `Deployment`. Inspect the admission annotations on a newly created Pod during its initialization window:

```bash
kubectl -n pod-rightsizing get pod -l app=boosted-app -o jsonpath='{.items[0].metadata.annotations}{"\n"}'
```

And verify completed in-place unboost events:

```bash
kubectl -n pod-rightsizing get events --field-selector reason=InPlaceResizedByVPA
```

See [ADR-0004](docs/adr/0004-admission-only-boost-semantics-on-container-restart.md).

## 5. Resolving `PodResizePending: Deferred` before VPA's 5-minute `EvictedByVPA` fallback

### Symptom

1. A high-priority serving Pod on a tightly bin-packed node (>90% CPU request utilization) attempts to scale up in place (`updateMode: "InPlaceOrRecreate"`), gets stuck in `PodResizePending=True (reason=Deferred)` with a `ResizeDeferred` event, and after 5 minutes is evicted and recreated (`reason=EvictedByVPA`).
2. Or, when low-priority batch Pods are evicted to free room for the serving Pod, their ReplicaSet replacements preempt other normal default-priority (`0`) Pods on the node.

### Root cause

1. When `kubelet` cannot admit an in-place CPU or memory increase because other Pods occupy the node's allocatable capacity, it sets `PodResizePending: Deferred`. Under GKE VPA's `InPlaceOrRecreate` mode, an in-place resize that remains `Deferred` for more than 5 minutes (or `Infeasible` for more than 1 minute) falls back to Pod eviction (`EvictedByVPA`) so the Pod can be rescheduled onto a node with sufficient headroom.
2. In Kubernetes, the default priority is `0`. If a batch `PriorityClass` is given a positive value (such as `1000`) and `preemptionPolicy: PreemptLowerPriority`, replacement batch Pods can preempt normal `priority: 0` workloads.

### Fix and verification

1. Configure opportunistic scavenger/batch `PriorityClass` objects with a **negative** priority (`value: -10`) and `preemptionPolicy: Never`, while giving latency-sensitive serving workloads a high positive `PriorityClass` (`value: 1000000`, `preemptionPolicy: PreemptLowerPriority`).
2. Keep `terminationGracePeriodSeconds` short on preemptible batch Pods so `kubelet` can admit the deferred in-place resize (`ResizeCompleted`, `RESTARTS: 0`) within seconds of preemption (`InPlacePodVerticalScalingSchedulerPreemption` in Kubernetes 1.37 / KEP-5836):

```bash
kubectl -n pod-rightsizing-preemption get events \
  --field-selector reason=ResizeDeferred,reason=ResizeCompleted
```

See [ADR-0005](docs/adr/0005-priority-preemption-for-deferred-in-place-pod-resize.md).
