#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NAMESPACE="pod-rightsizing"
VPA_NAME="boosted-app-vpa"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_PREFIX="verify-startup-boost"
LOG_TIMESTAMP="true"
# shellcheck source=hack/lib.sh
source "${SCRIPT_DIR}/lib.sh"

VPA_MANIFEST="${REPO_ROOT}/manifests/01-startup-boost/01-vpa-startup-boost.yaml"
WORKLOAD_MANIFEST="${REPO_ROOT}/manifests/01-startup-boost/02-workloads.yaml"
MAKEFILE_PATH="${REPO_ROOT}/Makefile"
WATCH_SCRIPT="${REPO_ROOT}/hack/watch-startup-boost.sh"

log "Step 1: Checking required Demo 01 files and cluster hygiene..."
[[ -f "${VPA_MANIFEST}" ]] || fail "Missing VPA manifest: ${VPA_MANIFEST}"
[[ -f "${WORKLOAD_MANIFEST}" ]] || fail "Missing workloads manifest: ${WORKLOAD_MANIFEST}"
[[ -f "${MAKEFILE_PATH}" ]] || fail "Missing Makefile: ${MAKEFILE_PATH}"
[[ -x "${WATCH_SCRIPT}" ]] || fail "Missing or non-executable watch script: ${WATCH_SCRIPT}"
check_no_banned_terms "${REPO_ROOT}/manifests/" "${MAKEFILE_PATH}" "${REPO_ROOT}/hack/"
pass "Demo 01 manifests, scripts, and hygiene checks passed."

log "Step 2: Resetting and applying Demo 01 (01-startup-boost)..."
make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" clean-startup-boost >/dev/null 2>&1 || true
kubectl --context="${KUBE_CONTEXT}" wait --for=delete namespace/"${NAMESPACE}" --timeout=60s >/dev/null 2>&1 || true

kubectl --context="${KUBE_CONTEXT}" apply -f "${VPA_MANIFEST}" >/dev/null
sleep 3
kubectl --context="${KUBE_CONTEXT}" apply -f "${WORKLOAD_MANIFEST}" >/dev/null

log "Step 3: Verifying VPA admission webhook injected vpaCpuStartupBoost/app and 4x CPU boost (250m -> 1000m) on boosted-app..."
MAX_ADMISSION_WAIT=45
T0="$(date +%s)"
BOOSTED_POD=""
THROTTLED_POD=""

while true; do
  NOW="$(date +%s)"
  if (( NOW - T0 > MAX_ADMISSION_WAIT )); then
    fail "Timed out waiting for boosted-app and throttled-app Pods to be created"
  fi
  BOOSTED_POD="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=boosted-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  THROTTLED_POD="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=throttled-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${BOOSTED_POD}" && -n "${THROTTLED_POD}" ]]; then
    break
  fi
  sleep 1
done

BOOST_POD_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod "${BOOSTED_POD}" -o json)"
python3 - "${BOOST_POD_JSON}" <<'PY'
import json
import sys

pod = json.loads(sys.argv[1])
anns = pod.get("metadata", {}).get("annotations", {})
boost_key = "vpaCPUStartupBoost/app" if "vpaCPUStartupBoost/app" in anns else ("vpaCpuStartupBoost/app" if "vpaCpuStartupBoost/app" in anns else None)
assert boost_key is not None, f"Expected vpaCPUStartupBoost/app annotation on {pod['metadata']['name']}, got {anns}"
boost_meta = json.loads(anns[boost_key])
assert boost_meta.get("requests", {}).get("cpu") == "250m", f"Expected baseline requests.cpu=250m in annotation, got {boost_meta}"

c = pod["spec"]["containers"][0]
req_cpu = c["resources"]["requests"]["cpu"]
lim_cpu = c["resources"]["limits"]["cpu"]
assert req_cpu in ("1", "1000m"), f"Expected boosted requests.cpu in ('1', '1000m'), got {req_cpu}"
assert lim_cpu in ("1", "1000m"), f"Expected boosted limits.cpu in ('1', '1000m'), got {lim_cpu}"
print(f"  Verified {pod['metadata']['name']}: {boost_key}={anns[boost_key]}, active spec CPU={req_cpu}/{lim_cpu}")
PY
pass "Admission-time VPA CPU Startup Boost verified (1000m active, 250m baseline recorded in vpaCpuStartupBoost/app)."

log "Step 4: Waiting for both boosted-app and throttled-app to finish initialization and become Ready..."
kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" wait --for=condition=Ready "pod/${BOOSTED_POD}" --timeout=90s >/dev/null
pass "boosted-app (${BOOSTED_POD}) reached Ready=True!"
kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" wait --for=condition=Ready "pod/${THROTTLED_POD}" --timeout=120s >/dev/null
pass "throttled-app (${THROTTLED_POD}) reached Ready=True!"

log "Step 5: Comparing startup duration and Linux cgroup v2 CFS throttling (/tmp/rightsizing-report)..."
sleep 2
BOOST_REPORT="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${BOOSTED_POD}" -- cat /tmp/rightsizing-report)"
THROTTLE_REPORT="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${THROTTLED_POD}" -- cat /tmp/rightsizing-report)"

python3 - "${BOOST_REPORT}" "${THROTTLE_REPORT}" <<'PY'
import sys

def parse(raw):
    d = {}
    for line in raw.splitlines():
        if "=" in line:
            k, v = line.strip().split("=", 1)
            d[k] = v
    return d

b = parse(sys.argv[1])
t = parse(sys.argv[2])

b_ms = int(b["STARTUP_MS"])
t_ms = int(t["STARTUP_MS"])
b_thr = int(b["STARTUP_NR_THROTTLED"])
t_thr = int(t["STARTUP_NR_THROTTLED"])
speedup = t_ms / max(b_ms, 1)

print(f"  boosted-app:   BOOT_CPU={b['BOOT_CPU_MAX_MC']}, STARTUP_MS={b_ms}ms, STARTUP_NR_THROTTLED={b_thr}")
print(f"  throttled-app: BOOT_CPU={t['BOOT_CPU_MAX_MC']}, STARTUP_MS={t_ms}ms, STARTUP_NR_THROTTLED={t_thr}")
print(f"  Speedup:       {speedup:.2f}x faster cold start")

assert b["BOOT_CPU_MAX_MC"] == "1000m", f"Expected boosted-app BOOT_CPU_MAX_MC=1000m, got {b['BOOT_CPU_MAX_MC']}"
assert t["BOOT_CPU_MAX_MC"] == "250m", f"Expected throttled-app BOOT_CPU_MAX_MC=250m, got {t['BOOT_CPU_MAX_MC']}"
assert t_ms > b_ms * 2, f"Expected throttled-app startup ({t_ms}ms) to be >2x slower than boosted-app ({b_ms}ms)"
assert t_thr > b_thr + 20, f"Expected throttled-app nr_throttled ({t_thr}) to be much higher than boosted-app ({b_thr})"
PY
pass "Container cgroup v2 startup telemetry verified: boosted-app avoided CFS throttling and initialized >2x faster."

log "Step 6: Waiting for VPA Updater 1-minute evaluation cycle to perform Zero-Restart In-Place Unboost (1000m -> 250m, reason=InPlaceResizedByVPA)..."
T_UNBOOST_START="$(date +%s)"
MAX_UNBOOST_WAIT="${MAX_UNBOOST_WAIT:-180}"

while true; do
  NOW="$(date +%s)"
  ELAPSED=$((NOW - T_UNBOOST_START))
  if (( ELAPSED > MAX_UNBOOST_WAIT )); then
    fail "Timed out after ${MAX_UNBOOST_WAIT}s waiting for In-Place Unboost on ${BOOSTED_POD}"
  fi

  POD_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pod "${BOOSTED_POD}" -o json)"
  EVENTS_JSON="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get events --field-selector reason=InPlaceResizedByVPA -o json)"
  LIVE_REP="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${BOOSTED_POD}" -- cat /tmp/rightsizing-report 2>/dev/null || true)"

  STATUS_LINE="$(python3 - "${POD_JSON}" "${EVENTS_JSON}" "${LIVE_REP}" <<'PY'
import json
import sys

pod = json.loads(sys.argv[1])
events = json.loads(sys.argv[2]).get("items", [])
rep_raw = sys.argv[3]
rep = dict(line.strip().split("=", 1) for line in rep_raw.splitlines() if "=" in line)

c_spec = pod["spec"]["containers"][0]
req_cpu = c_spec["resources"]["requests"]["cpu"]
lim_cpu = c_spec["resources"]["limits"]["cpu"]
restarts = pod["status"]["containerStatuses"][0]["restartCount"]
qos = pod["status"].get("qosClass", "Unknown")
has_ann = ("vpaCPUStartupBoost/app" in pod["metadata"].get("annotations", {})) or ("vpaCpuStartupBoost/app" in pod["metadata"].get("annotations", {}))
live_cgroup = rep.get("LIVE_CPU_MAX_MC", "unknown")
ev_count = len(events)

done = (req_cpu == "250m" and lim_cpu == "250m" and live_cgroup == "250m" and ev_count >= 1 and restarts == 0)
print(f"DONE={done}|spec={req_cpu}/{lim_cpu}|live_cgroup={live_cgroup}|restarts={restarts}|qos={qos}|boost_ann={has_ann}|events={ev_count}")
PY
)"
  log "[+${ELAPSED}s] ${STATUS_LINE}"
  if [[ "${STATUS_LINE}" == "DONE=True|"* ]]; then
    pass "In-Place Unboost completed at +${ELAPSED}s: CPU restored to 250m/250m in Pod spec and live container cgroup with RESTARTS=0!"
    break
  fi
  sleep 5
done

log "Step 7: Capturing 'make status' output after In-Place Unboost..."
FINAL_STATUS="$(make --no-print-directory -C "${REPO_ROOT}" KUBE_CONTEXT="${KUBE_CONTEXT}" status)"
echo "${FINAL_STATUS}"
pass "Demo 01 (01-startup-boost) end-to-end verification succeeded!"
