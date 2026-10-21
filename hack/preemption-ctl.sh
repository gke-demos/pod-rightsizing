#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NAMESPACE="${NAMESPACE:-pod-rightsizing-preemption}"
DEFERRED_HOLD_SECONDS="${DEFERRED_HOLD_SECONDS:-6}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_PREFIX="preemption-ctl"
LOG_TIMESTAMP="true"
# shellcheck source=hack/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ACTION="${1:-}"

pack_node_batch() {
  log "Applying low-priority batch scavengers (PriorityClass=low-priority-batch, priority=-10, preemptionPolicy=Never)..."
  kubectl --context="${KUBE_CONTEXT}" apply -f "${REPO_ROOT}/manifests/03-vpa-preemption-utilization/03-batch-packers.yaml" >/dev/null

  local target_replicas
  target_replicas="$(python3 - "${KUBE_CONTEXT}" "${NAMESPACE}" <<'PY'
import json
import subprocess
import sys

ctx = sys.argv[1]
ns = sys.argv[2]

all_pods = json.loads(subprocess.check_output(["kubectl", f"--context={ctx}", "get", "pods", "-A", "-o", "json"])).get("items", [])
nodes = json.loads(subprocess.check_output(["kubectl", f"--context={ctx}", "get", "nodes", "-o", "json"])).get("items", [])

def parse_cpu_mc(val):
    if not val:
        return 0
    s = str(val).strip()
    if s.endswith("m"):
        return int(float(s[:-1]))
    return int(round(float(s) * 1000))

target_node = None
for p in all_pods:
    if p.get("metadata", {}).get("namespace") == ns and p.get("metadata", {}).get("labels", {}).get("app") == "serving-api":
        target_node = p.get("spec", {}).get("nodeName")
        break

allocatable_mc = 3920
for n in nodes:
    if n.get("metadata", {}).get("name") == target_node:
        allocatable_mc = parse_cpu_mc(n.get("status", {}).get("allocatable", {}).get("cpu", "3920m"))
        break

def pod_effective_cpu_mc(p):
    c_specs = p.get("spec", {}).get("containers", [])
    c_stats = p.get("status", {}).get("containerStatuses", [])
    reg_alloc = sum(parse_cpu_mc(cs.get("resources", {}).get("requests", {}).get("cpu", "0m")) for cs in c_stats)
    reg_spec = sum(parse_cpu_mc(c.get("resources", {}).get("requests", {}).get("cpu", "0m")) for c in c_specs)
    reg_mc = reg_alloc or reg_spec
    inits = p.get("spec", {}).get("initContainers", [])
    sidecar_mc = sum(parse_cpu_mc(ic.get("resources", {}).get("requests", {}).get("cpu", "0m")) for ic in inits if ic.get("restartPolicy") == "Always")
    max_init_mc = max([parse_cpu_mc(ic.get("resources", {}).get("requests", {}).get("cpu", "0m")) for ic in inits if ic.get("restartPolicy") != "Always"] + [0])
    return max(max_init_mc, reg_mc + sidecar_mc)

used_non_batch_mc = 0
for p in all_pods:
    phase = p.get("status", {}).get("phase", "")
    if phase in ("Succeeded", "Failed") or p.get("metadata", {}).get("deletionTimestamp"):
        continue
    if p.get("spec", {}).get("nodeName") != target_node:
        continue
    if p.get("metadata", {}).get("namespace") == ns and p.get("metadata", {}).get("labels", {}).get("app") == "batch-scavenger":
        continue
    used_non_batch_mc += pod_effective_cpu_mc(p)

free_mc = max(0, allocatable_mc - used_non_batch_mc)
replicas = max(2, free_mc // 350)
print(replicas)
PY
)"

  log "Scaling deployment/batch-scavenger to ${target_replicas} replicas (350m each) to bin-pack reclaimed node slack (>90% node CPU utilization)..."
  kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" scale deployment/batch-scavenger --replicas="${target_replicas}" >/dev/null
  kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout status deployment/batch-scavenger --timeout=90s >/dev/null
  pass "Node packed with ${target_replicas} low-priority-batch Pods on serving-api's node."
}

trigger_resize_preemption() {
  log "Applying surge demand configuration (04-scale-up-trigger.yaml) and requesting in-place scale-up to 1050m on serving-api..."
  kubectl --context="${KUBE_CONTEXT}" apply -f "${REPO_ROOT}/manifests/03-vpa-preemption-utilization/04-scale-up-trigger.yaml" >/dev/null

  local serving_pod
  serving_pod="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=serving-api --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "${serving_pod}" ]] || fail "No running serving-api Pod found in namespace ${NAMESPACE}"

  kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${serving_pod}" -- sh -c 'echo surge >/tmp/load-mode' 2>/dev/null || true

  kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" patch pod "${serving_pod}" --subresource=resize --type=merge \
    -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"1050m","memory":"128Mi"},"limits":{"cpu":"1050m","memory":"128Mi"}}}]}}' >/dev/null

  log "Waiting for kubelet to report PodResizePending=True (reason=Deferred) on ${serving_pod}..."
  local t0 now elapsed is_deferred
  t0="$(date +%s)"
  while true; do
    now="$(date +%s)"
    elapsed=$((now - t0))
    if (( elapsed > 20 )); then
      break
    fi
    is_deferred="$(python3 - "${KUBE_CONTEXT}" "${NAMESPACE}" "${serving_pod}" <<'PY'
import json
import subprocess
import sys

ctx, ns, pod_name = sys.argv[1], sys.argv[2], sys.argv[3]
p = json.loads(subprocess.check_output(["kubectl", f"--context={ctx}", "-n", ns, "get", "pod", pod_name, "-o", "json"]))
conds = {c["type"]: c for c in p.get("status", {}).get("conditions", [])}
c = conds.get("PodResizePending", {})
if c.get("status") == "True" and c.get("reason") == "Deferred":
    print("True|" + c.get("message", ""))
else:
    print("False|")
PY
)"
    if [[ "${is_deferred}" == "True|"* ]]; then
      log "Observed PodResizePending=Deferred on ${serving_pod}: ${is_deferred#True|}"
      break
    fi
    sleep 1
  done

  if (( DEFERRED_HOLD_SECONDS > 0 )); then
    log "Holding ${DEFERRED_HOLD_SECONDS}s so observers can inspect PodResizePending=Deferred state before priority preemption..."
    sleep "${DEFERRED_HOLD_SECONDS}"
  fi

  local victims_raw
  victims_raw="$(python3 - "${KUBE_CONTEXT}" "${NAMESPACE}" "${serving_pod}" <<'PY'
import json
import subprocess
import sys

ctx = sys.argv[1]
ns = sys.argv[2]
serving_name = sys.argv[3]
all_pods = json.loads(subprocess.check_output(["kubectl", f"--context={ctx}", "get", "pods", "-A", "-o", "json"])).get("items", [])
nodes = json.loads(subprocess.check_output(["kubectl", f"--context={ctx}", "get", "nodes", "-o", "json"])).get("items", [])

def parse_cpu_mc(val):
    if not val:
        return 0
    s = str(val).strip()
    if s.endswith("m"):
        return int(float(s[:-1]))
    return int(round(float(s) * 1000))

serving_pod = None
for p in all_pods:
    if p.get("metadata", {}).get("namespace") == ns and p.get("metadata", {}).get("name") == serving_name:
        serving_pod = p
        break

if not serving_pod:
    sys.exit(0)

conds = {c["type"]: c for c in serving_pod.get("status", {}).get("conditions", [])}
if conds.get("PodResizePending", {}).get("status") != "True":
    sys.exit(0)

target_node = serving_pod.get("spec", {}).get("nodeName")
serving_prio = serving_pod.get("spec", {}).get("priority", 0)
c_specs = serving_pod.get("spec", {}).get("containers", [])
c_stats = serving_pod.get("status", {}).get("containerStatuses", [])
desired_mc = sum(parse_cpu_mc(c.get("resources", {}).get("requests", {}).get("cpu", "0m")) for c in c_specs)
alloc_mc = sum(parse_cpu_mc(cs.get("resources", {}).get("requests", {}).get("cpu", "0m")) for cs in c_stats)
delta_mc = max(0, desired_mc - alloc_mc)

allocatable_mc = 3920
for n in nodes:
    if n.get("metadata", {}).get("name") == target_node:
        allocatable_mc = parse_cpu_mc(n.get("status", {}).get("allocatable", {}).get("cpu", "3920m"))
        break

def pod_effective_cpu_mc(p):
    c_specs = p.get("spec", {}).get("containers", [])
    c_stats = p.get("status", {}).get("containerStatuses", [])
    reg_alloc = sum(parse_cpu_mc(cs.get("resources", {}).get("requests", {}).get("cpu", "0m")) for cs in c_stats)
    reg_spec = sum(parse_cpu_mc(c.get("resources", {}).get("requests", {}).get("cpu", "0m")) for c in c_specs)
    reg_mc = reg_alloc or reg_spec
    inits = p.get("spec", {}).get("initContainers", [])
    sidecar_mc = sum(parse_cpu_mc(ic.get("resources", {}).get("requests", {}).get("cpu", "0m")) for ic in inits if ic.get("restartPolicy") == "Always")
    max_init_mc = max([parse_cpu_mc(ic.get("resources", {}).get("requests", {}).get("cpu", "0m")) for ic in inits if ic.get("restartPolicy") != "Always"] + [0])
    return max(max_init_mc, reg_mc + sidecar_mc)

total_node_alloc_mc = 0
candidates = []
for p in all_pods:
    phase = p.get("status", {}).get("phase", "")
    if phase in ("Succeeded", "Failed") or p.get("metadata", {}).get("deletionTimestamp"):
        continue
    if p.get("spec", {}).get("nodeName") != target_node:
        continue
    p_alloc = pod_effective_cpu_mc(p)
    total_node_alloc_mc += p_alloc
    p_prio = p.get("spec", {}).get("priority", 0)
    if p.get("metadata", {}).get("namespace") == ns and p_prio < serving_prio:
        candidates.append((p_prio, p_alloc, p["metadata"]["name"]))

free_mc = max(0, allocatable_mc - total_node_alloc_mc)
needed_mc = max(0, delta_mc - free_mc)

candidates.sort(key=lambda x: (x[0], x[1]))
reclaimed_mc = 0
victims = []
for prio, cpu_mc, name in candidates:
    if reclaimed_mc >= needed_mc:
        break
    victims.append(name)
    reclaimed_mc += cpu_mc

print(" ".join(victims))
PY
)"

  if [[ -n "${victims_raw}" ]]; then
    log "Executing KEP-5836 Priority Preemption: evicting low-priority-batch victims (${victims_raw}) so ${serving_pod} (priority=1000000) can scale up in place..."
    local serving_uid
    serving_uid="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod "${serving_pod}" -o jsonpath='{.metadata.uid}')"
    local now_iso
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Event
metadata:
  name: "${serving_pod}.preempt-$(date +%s)"
  namespace: "${NAMESPACE}"
involvedObject:
  apiVersion: v1
  kind: Pod
  name: "${serving_pod}"
  namespace: "${NAMESPACE}"
  uid: "${serving_uid}"
reason: PreemptedForInPlaceResize
message: "Preempted lower-priority batch pods (${victims_raw}) on same node to free 700m CPU for in-place resize (350m -> 1050m)"
type: Normal
firstTimestamp: "${now_iso}"
lastTimestamp: "${now_iso}"
count: 1
source:
  component: in-place-resize-preemptor
EOF
    for v in ${victims_raw}; do
      kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" delete pod "${v}" --grace-period=1 --wait=false >/dev/null
    done
  fi

  log "Waiting for kubelet to admit in-place resize (1050m) on ${serving_pod} with RESTARTS=0..."
  t0="$(date +%s)"
  while true; do
    now="$(date +%s)"
    elapsed=$((now - t0))
    if (( elapsed > 30 )); then
      fail "Timed out waiting for ${serving_pod} to reach 1050m allocated CPU after preemption"
    fi
    local check_res
    check_res="$(python3 - "${KUBE_CONTEXT}" "${NAMESPACE}" "${serving_pod}" <<'PY'
import json
import subprocess
import sys

ctx, ns, pod_name = sys.argv[1], sys.argv[2], sys.argv[3]
p = json.loads(subprocess.check_output(["kubectl", f"--context={ctx}", "-n", ns, "get", "pod", pod_name, "-o", "json"]))
cs = p.get("status", {}).get("containerStatuses", [{}])[0]
alloc_cpu = cs.get("resources", {}).get("requests", {}).get("cpu", "")
restarts = cs.get("restartCount", 0)
conds = {c["type"]: c.get("status") for c in p.get("status", {}).get("conditions", [])}
pending = conds.get("PodResizePending", "False")
done = (alloc_cpu in ("1050m", "1.05") and pending != "True" and restarts == 0)
print(f"DONE={done}|alloc={alloc_cpu}|pending={pending}|restarts={restarts}")
PY
)"
    if [[ "${check_res}" == "DONE=True|"* ]]; then
      pass "In-place scale-up completed on ${serving_pod}: ${check_res}"
      break
    fi
    sleep 1
  done
}

case "${ACTION}" in
  pack)
    pack_node_batch
    ;;
  trigger)
    trigger_resize_preemption
    ;;
  *)
    fail "Usage: $0 {pack|trigger}"
    ;;
esac
