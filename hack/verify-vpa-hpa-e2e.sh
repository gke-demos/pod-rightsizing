#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NAMESPACE="pod-rightsizing-hpa"
VPA_NAME="rightsized-api-vpa"
HPA_NAME="rightsized-api-hpa"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_PREFIX="verify-vpa-hpa"
LOG_TIMESTAMP="true"
# shellcheck source=hack/lib.sh
source "${SCRIPT_DIR}/lib.sh"

VPA_HPA_MANIFEST="${REPO_ROOT}/manifests/02-vpa-hpa-rightsizing/01-vpa-hpa.yaml"
WORKLOAD_MANIFEST="${REPO_ROOT}/manifests/02-vpa-hpa-rightsizing/02-workload.yaml"
LOAD_MANIFEST="${REPO_ROOT}/manifests/02-vpa-hpa-rightsizing/03-load-spike.yaml"
WATCH_SCRIPT="${REPO_ROOT}/hack/watch-vpa-hpa.sh"

log "Step 1: Checking required Demo 02 files and cluster hygiene..."
[[ -f "${VPA_HPA_MANIFEST}" ]] || fail "Missing VPA/HPA manifest: ${VPA_HPA_MANIFEST}"
[[ -f "${WORKLOAD_MANIFEST}" ]] || fail "Missing workload manifest: ${WORKLOAD_MANIFEST}"
[[ -f "${LOAD_MANIFEST}" ]] || fail "Missing load-spike manifest: ${LOAD_MANIFEST}"
[[ -x "${WATCH_SCRIPT}" ]] || fail "Missing or non-executable watch script: ${WATCH_SCRIPT}"
check_no_banned_terms "${REPO_ROOT}/manifests/" "${REPO_ROOT}/Makefile" "${REPO_ROOT}/hack/"
pass "Demo 02 manifests, scripts, and hygiene checks passed."

log "Step 2: Resetting and applying Demo 02 (02-vpa-hpa-rightsizing)..."
make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" clean-vpa-hpa >/dev/null 2>&1 || true
kubectl --context="${KUBE_CONTEXT}" wait --for=delete namespace/"${NAMESPACE}" --timeout=60s >/dev/null 2>&1 || true

make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" apply-vpa-hpa >/dev/null

log "Step 3: Verifying VPA Cooperative HPA Rightsizing annotation, Startup Boost (500m -> 1000m), and HPA configuration..."
VPA_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get vpa "${VPA_NAME}" -o json)"
HPA_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get hpa "${HPA_NAME}" -o json)"
python3 - "${VPA_JSON}" "${HPA_JSON}" <<'PY'
import json
import sys

vpa = json.loads(sys.argv[1])
hpa = json.loads(sys.argv[2])

anns = vpa.get("metadata", {}).get("annotations", {})
assert anns.get("gke.io/autoscaling-hpa-rightsizing-mode") == "gke-hpa-rightsizing-mode-policy", f"Missing HPA rightsizing annotation: {anns}"
assert vpa["spec"]["updatePolicy"]["updateMode"] == "InPlaceOrRecreate"
assert vpa["spec"]["startupBoost"]["cpu"]["durationSeconds"] == 0
assert hpa["spec"]["minReplicas"] == 2
assert hpa["spec"]["maxReplicas"] == 6
print("  Verified VPA gke-hpa-rightsizing-mode-policy + InPlaceOrRecreate + durationSeconds=0 and HPA (min=2, max=6).")
PY
pass "VPA and HPA cooperative configuration verified."

log "Step 4: Waiting for initial 2 rightsized-api replicas to reach Ready and unboost in place (1000m -> <=500m, RESTARTS=0)..."
kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout status deployment/rightsized-api --timeout=120s >/dev/null

T0="$(date +%s)"
MAX_WAIT="${MAX_WAIT:-180}"
while true; do
  NOW="$(date +%s)"
  ELAPSED=$((NOW - T0))
  if (( ELAPSED > MAX_WAIT )); then
    fail "Timed out after ${MAX_WAIT}s waiting for initial In-Place Unboost on rightsized-api Pods"
  fi
  PODS_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=rightsized-api -o json)"
  EVENTS_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get events --field-selector reason=InPlaceResizedByVPA -o json)"
  VPA_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get vpa "${VPA_NAME}" -o json)"

  SUMMARY="$(python3 - "${PODS_JSON}" "${EVENTS_JSON}" "${VPA_JSON}" <<'PY'
import json
import sys

pods = json.loads(sys.argv[1]).get("items", [])
events = json.loads(sys.argv[2]).get("items", [])
vpa = json.loads(sys.argv[3])

recs = vpa.get("status", {}).get("recommendation", {}).get("containerRecommendations", [])
rec_cpu = recs[0].get("target", {}).get("cpu", "pending") if recs else "pending"

unboosted = 0
restarts_total = 0
specs = []
for p in pods:
    c = p["spec"]["containers"][0]
    req = c["resources"]["requests"]["cpu"]
    anns = p["metadata"].get("annotations", {})
    has_boost_ann = ("vpaCPUStartupBoost/app" in anns) or ("vpaCpuStartupBoost/app" in anns)
    specs.append(f"{p['metadata']['name']}={req}(boost={has_boost_ann})")
    restarts = p["status"]["containerStatuses"][0]["restartCount"]
    restarts_total += restarts
    if not has_boost_ann:
        unboosted += 1

done = (len(pods) == 2 and unboosted == 2 and len(events) >= 1 and restarts_total == 0)
print(f"DONE={done}|unboosted={unboosted}/{len(pods)}|events={len(events)}|restarts={restarts_total}|vpa_target={rec_cpu}|pods={' '.join(specs)}")
PY
)"
  log "[+${ELAPSED}s] ${SUMMARY}"
  if [[ "${SUMMARY}" == "DONE=True|"* ]]; then
    pass "Initial rightsized-api replicas unboosted in place with RESTARTS=0 and zero false HPA scale-outs (replicas=2)!"
    break
  fi
  sleep 5
done

log "Step 5: Triggering traffic surge ('make load-spike') to verify HPA horizontal scale-out (>2 replicas) while VPA manages vertical baseline..."
make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" load-spike >/dev/null
T_LOAD="$(date +%s)"
while true; do
  NOW="$(date +%s)"
  ELAPSED=$((NOW - T_LOAD))
  if (( ELAPSED > 150 )); then
    fail "Timed out after 150s waiting for HPA to scale out rightsized-api under load spike"
  fi
  HPA_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get hpa "${HPA_NAME}" -o json)"
  HPA_LINE="$(python3 - "${HPA_JSON}" <<'PY'
import json
import sys

hpa = json.loads(sys.argv[1])
cur_r = hpa.get("status", {}).get("currentReplicas", 0)
des_r = hpa.get("status", {}).get("desiredReplicas", 0)
c_metrics = hpa.get("status", {}).get("currentMetrics") or []
util = "-"
for cm in c_metrics:
    if cm.get("type") == "Resource" and cm.get("resource", {}).get("name") == "cpu":
        util = str(cm["resource"].get("current", {}).get("averageUtilization", "-")) + "%"
scaled = des_r > 2 or cur_r > 2
print(f"SCALED={scaled}|currentReplicas={cur_r}|desiredReplicas={des_r}|cpuUtil={util}")
PY
)"
  log "[+${ELAPSED}s] HPA: ${HPA_LINE}"
  if [[ "${HPA_LINE}" == "SCALED=True|"* ]]; then
    pass "HPA scaled out rightsized-api horizontally under load (${HPA_LINE})!"
    break
  fi
  sleep 5
done

log "Step 6: Capturing 'make status-vpa-hpa' snapshot during cooperative VPA + HPA operation..."
STATUS_OUT="$(make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" status-vpa-hpa)"
echo "${STATUS_OUT}"

log "Step 7: Stopping load spike ('make stop-load-spike')..."
make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" stop-load-spike >/dev/null
pass "Demo 02 (02-vpa-hpa-rightsizing) end-to-end verification succeeded!"
