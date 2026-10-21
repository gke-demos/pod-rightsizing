#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NAMESPACE="pod-rightsizing-preemption"
VPA_NAME="serving-api-vpa"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_PREFIX="verify-vpa-preemption"
LOG_TIMESTAMP="true"
# shellcheck source=hack/lib.sh
source "${SCRIPT_DIR}/lib.sh"

PRIO_VPA_MANIFEST="${REPO_ROOT}/manifests/03-vpa-preemption-utilization/01-priority-vpa.yaml"
SERVING_MANIFEST="${REPO_ROOT}/manifests/03-vpa-preemption-utilization/02-serving-workload.yaml"
BATCH_MANIFEST="${REPO_ROOT}/manifests/03-vpa-preemption-utilization/03-batch-packers.yaml"
TRIGGER_MANIFEST="${REPO_ROOT}/manifests/03-vpa-preemption-utilization/04-scale-up-trigger.yaml"
WATCH_SCRIPT="${REPO_ROOT}/hack/watch-vpa-preemption.sh"
CTL_SCRIPT="${REPO_ROOT}/hack/preemption-ctl.sh"

log "Step 1: Checking required Demo 03 files and cluster hygiene..."
[[ -f "${PRIO_VPA_MANIFEST}" ]] || fail "Missing PriorityClass/VPA manifest: ${PRIO_VPA_MANIFEST}"
[[ -f "${SERVING_MANIFEST}" ]] || fail "Missing serving workload manifest: ${SERVING_MANIFEST}"
[[ -f "${BATCH_MANIFEST}" ]] || fail "Missing batch packers manifest: ${BATCH_MANIFEST}"
[[ -f "${TRIGGER_MANIFEST}" ]] || fail "Missing scale-up trigger manifest: ${TRIGGER_MANIFEST}"
[[ -x "${WATCH_SCRIPT}" ]] || fail "Missing or non-executable watch script: ${WATCH_SCRIPT}"
[[ -x "${CTL_SCRIPT}" ]] || fail "Missing or non-executable control script: ${CTL_SCRIPT}"
check_no_banned_terms "${REPO_ROOT}/manifests/" "${REPO_ROOT}/Makefile" "${REPO_ROOT}/hack/"
pass "Demo 03 manifests, scripts, and hygiene checks passed."

log "Step 2: Resetting and applying Demo 03 (03-vpa-preemption-utilization)..."
make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" clean-vpa-preemption >/dev/null 2>&1 || true
kubectl --context="${KUBE_CONTEXT}" wait --for=delete namespace/"${NAMESPACE}" --timeout=60s >/dev/null 2>&1 || true

make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" apply-vpa-preemption >/dev/null

log "Step 3: Verifying PriorityClasses (high-priority-serving=1000000, low-priority-batch=-10) and VPA InPlaceOrRecreate..."
HI_PRIO="$(kubectl --context="${KUBE_CONTEXT}" get priorityclass high-priority-serving -o jsonpath='{.value}')"
LO_PRIO="$(kubectl --context="${KUBE_CONTEXT}" get priorityclass low-priority-batch -o jsonpath='{.value}')"
LO_POL="$(kubectl --context="${KUBE_CONTEXT}" get priorityclass low-priority-batch -o jsonpath='{.preemptionPolicy}')"
VPA_MODE="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get vpa "${VPA_NAME}" -o jsonpath='{.spec.updatePolicy.updateMode}')"
[[ "${HI_PRIO}" == "1000000" ]] || fail "Expected high-priority-serving=1000000, got ${HI_PRIO}"
[[ "${LO_PRIO}" == "-10" ]] || fail "Expected low-priority-batch=-10, got ${LO_PRIO}"
[[ "${LO_POL}" == "Never" ]] || fail "Expected low-priority-batch preemptionPolicy=Never, got ${LO_POL}"
[[ "${VPA_MODE}" == "InPlaceOrRecreate" ]] || fail "Expected updateMode=InPlaceOrRecreate, got ${VPA_MODE}"
pass "PriorityClasses and VPA InPlaceOrRecreate policy verified."

log "Step 4: Waiting for serving-api to reach Ready and rightsize down in place via VPA (1050m -> 350m, RESTARTS=0)..."
kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout status deployment/serving-api --timeout=120s >/dev/null

T0="$(date +%s)"
MAX_WAIT="${MAX_WAIT:-180}"
while true; do
  NOW="$(date +%s)"
  ELAPSED=$((NOW - T0))
  if (( ELAPSED > MAX_WAIT )); then
    fail "Timed out after ${MAX_WAIT}s waiting for VPA in-place downward resize on serving-api"
  fi
  POD_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=serving-api -o json)"
  EVENTS_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get events --field-selector reason=InPlaceResizedByVPA -o json)"
  SUMMARY="$(python3 - "${POD_JSON}" "${EVENTS_JSON}" <<'PY'
import json
import sys
pods = json.loads(sys.argv[1]).get("items", [])
events = json.loads(sys.argv[2]).get("items", [])
if not pods:
    print("DONE=False|no_pods")
    sys.exit(0)
p = pods[0]
c = p["spec"]["containers"][0]
req = c["resources"]["requests"]["cpu"]
cs = p.get("status", {}).get("containerStatuses", [{}])[0]
alloc = cs.get("resources", {}).get("requests", {}).get("cpu", req)
restarts = cs.get("restartCount", 0)
anns = p.get("metadata", {}).get("annotations", {})
has_boost = ("vpaCPUStartupBoost/app" in anns) or ("vpaCpuStartupBoost/app" in anns)
done = (not has_boost and alloc == "350m" and len(events) >= 1 and restarts == 0)
print(f"DONE={done}|req={req}|alloc={alloc}|boost={has_boost}|events={len(events)}|restarts={restarts}")
PY
)"
  log "[+${ELAPSED}s] ${SUMMARY}"
  if [[ "${SUMMARY}" == "DONE=True|"* ]]; then
    pass "serving-api rightsized down in place to 350m with RESTARTS=0, freeing 700m node CPU slack!"
    break
  fi
  sleep 5
done

log "Step 5: Packing reclaimed node slack with low-priority-batch Pods ('make pack-node-batch') to >90% node CPU utilization..."
make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" pack-node-batch
UTIL_SUMMARY="$(python3 - "${KUBE_CONTEXT}" "${NAMESPACE}" <<'PY'
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
    return int(float(s[:-1])) if s.endswith("m") else int(round(float(s) * 1000))
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
total_mc = 0
for p in all_pods:
    if p.get("status", {}).get("phase") in ("Succeeded", "Failed") or p.get("metadata", {}).get("deletionTimestamp"):
        continue
    if p.get("spec", {}).get("nodeName") == target_node:
        total_mc += pod_effective_cpu_mc(p)
pct = (total_mc * 100.0) / allocatable_mc
free_mc = allocatable_mc - total_mc
assert pct >= 90.0, f"Expected >=90% node CPU utilization, got {pct:.1f}%"
assert free_mc < 350, f"Expected <350m free CPU, got {free_mc}m"
print(f"Node CPU Utilization={pct:.1f}% ({total_mc}m/{allocatable_mc}m, {free_mc}m free)")
PY
)"
pass "Target node bin-packed above 90% CPU request utilization: ${UTIL_SUMMARY}"

log "Step 6: Triggering in-place scale-up to 1050m on serving-api ('make trigger-resize-preemption')..."
DEFERRED_HOLD_SECONDS=3 make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" trigger-resize-preemption

log "Step 7: Verifying ResizeDeferred -> PreemptedForInPlaceResize -> ResizeCompleted lifecycle and RESTARTS=0..."
POD_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=serving-api -o json)"
EVENTS_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get events -o json)"
python3 - "${POD_JSON}" "${EVENTS_JSON}" <<'PY'
import json
import sys

p = json.loads(sys.argv[1])["items"][0]
events = json.loads(sys.argv[2]).get("items", [])

cs = p["status"]["containerStatuses"][0]
alloc_cpu = cs["resources"]["requests"]["cpu"]
restarts = cs["restartCount"]
assert alloc_cpu in ("1050m", "1.05"), f"Expected allocated CPU 1050m, got {alloc_cpu}"
assert restarts == 0, f"Expected 0 restarts, got {restarts}"

reasons = {e.get("reason") for e in events}
for req_reason in ("InPlaceResizedByVPA", "ResizeDeferred", "PreemptedForInPlaceResize", "ResizeCompleted"):
    assert req_reason in reasons, f"Missing expected event reason {req_reason} in {reasons}"
print("  Verified events: InPlaceResizedByVPA -> ResizeDeferred -> PreemptedForInPlaceResize -> ResizeCompleted with RESTARTS=0!")
PY
pass "Complete VPA in-place down-sizing + >90% bin-packing + ResizeDeferred + Priority Preemption + ResizeCompleted verified!"

log "Step 8: Capturing 'make status-vpa-preemption' snapshot..."
STATUS_OUT="$(make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" status-vpa-preemption)"
echo "${STATUS_OUT}"
pass "Demo 03 (03-vpa-preemption-utilization) end-to-end verification succeeded!"
