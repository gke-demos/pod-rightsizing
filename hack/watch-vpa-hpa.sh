#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NAMESPACE="${NAMESPACE:-pod-rightsizing-hpa}"
VPA_NAME="${VPA_NAME:-rightsized-api-vpa}"
HPA_NAME="${HPA_NAME:-rightsized-api-hpa}"
WATCH_INTERVAL="${WATCH_INTERVAL:-4}"

ONCE="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once|-1)
      ONCE="true"
      shift
      ;;
    --interval|-n)
      WATCH_INTERVAL="${2:-4}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

render_snapshot() {
  local vpa_json hpa_json pods_json load_json events_json
  vpa_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get vpa "${VPA_NAME}" -o json 2>/dev/null || echo "{}")"
  hpa_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get hpa "${HPA_NAME}" -o json 2>/dev/null || echo "{}")"
  pods_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=rightsized-api -o json 2>/dev/null || echo '{"items":[]}')"
  load_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get configmap rightsized-api-load -o json 2>/dev/null || echo "{}")"
  events_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get events -o json 2>/dev/null || echo '{"items":[]}')"

  local reports_raw=""
  local pod_names
  pod_names="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l app=rightsized-api --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  for p in ${pod_names}; do
    local rep
    rep="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${p}" -- cat /tmp/rightsizing-report 2>/dev/null || true)"
    if [[ -n "${rep}" ]]; then
      reports_raw+="__POD_REPORT_START__:${p}"$'\n'"${rep}"$'\n'"__POD_REPORT_END__"$'\n'
    fi
  done

  python3 - "${KUBE_CONTEXT}" "${NAMESPACE}" "${vpa_json}" "${hpa_json}" "${pods_json}" "${load_json}" "${events_json}" "${reports_raw}" <<'PY'
import datetime
import json
import sys

ctx = sys.argv[1]
ns = sys.argv[2]
vpa = json.loads(sys.argv[3] or "{}")
hpa = json.loads(sys.argv[4] or "{}")
pods = json.loads(sys.argv[5] or '{"items":[]}').get("items", [])
load_dep = json.loads(sys.argv[6] or "{}")
events = json.loads(sys.argv[7] or '{"items":[]}').get("items", [])
reports_raw = sys.argv[8]

BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[1;36m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
MAGENTA = "\033[1;35m"
RED = "\033[1;31m"
RESET = "\033[0m"

def norm_cpu(val):
    if not val or val == "-":
        return "-"
    s = str(val).strip()
    if s.endswith("m"):
        return s
    try:
        f = float(s)
        return f"{int(round(f * 1000))}m"
    except Exception:
        return s

reports = {}
current_pod = None
for line in reports_raw.splitlines():
    if line.startswith("__POD_REPORT_START__:"):
        current_pod = line.split(":", 1)[1].strip()
        reports[current_pod] = {}
    elif line == "__POD_REPORT_END__":
        current_pod = None
    elif current_pod and "=" in line:
        k, v = line.strip().split("=", 1)
        reports[current_pod][k.strip()] = v.strip()

now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
print(f"{BOLD}{CYAN}=== GKE 1.37 Cooperative VPA + HPA CPU Rightsizing Observer ({now_utc}) ==={RESET}")
print(f"{DIM}Namespace: {ns} | VPA: rightsized-api-vpa | HPA: rightsized-api-hpa{RESET}\n")

# Section 1: Cooperative VPA + HPA Status
print(f"{BOLD}[1] Cooperative VPA + HPA Control Planes{RESET}")
if not vpa or "spec" not in vpa:
    print(f"  {RED}VerticalPodAutoscaler/rightsized-api-vpa not found{RESET}")
else:
    anns = vpa.get("metadata", {}).get("annotations", {})
    mode_ann = anns.get("gke.io/autoscaling-hpa-rightsizing-mode", "<missing>")
    up_mode = vpa.get("spec", {}).get("updatePolicy", {}).get("updateMode", "Unknown")
    sb_cpu = vpa.get("spec", {}).get("startupBoost", {}).get("cpu", {})
    sb_desc = f"{sb_cpu.get('type','Factor')} {sb_cpu.get('factor','2')}x (durationSeconds={sb_cpu.get('durationSeconds',0)}s)"
    recs = vpa.get("status", {}).get("recommendation", {}).get("containerRecommendations", [])
    rec_target = norm_cpu(recs[0].get("target", {}).get("cpu", "-")) if recs else "collecting..."
    rec_lower = norm_cpu(recs[0].get("lowerBound", {}).get("cpu", "-")) if recs else "-"
    rec_upper = norm_cpu(recs[0].get("upperBound", {}).get("cpu", "-")) if recs else "-"
    print(
        f"  VPA Policy: annotation={GREEN}{mode_ann}{RESET} | "
        f"updateMode={GREEN}{up_mode}{RESET} | startupBoost={MAGENTA}{sb_desc}{RESET}"
    )
    print(
        f"  VPA Recommendation (app): Target={YELLOW}{BOLD}{rec_target}{RESET} "
        f"(LowerBound={rec_lower}, UpperBound={rec_upper})"
    )

if not hpa or "spec" not in hpa:
    print(f"  {RED}HorizontalPodAutoscaler/rightsized-api-hpa not found{RESET}\n")
else:
    min_r = hpa.get("spec", {}).get("minReplicas", 2)
    max_r = hpa.get("spec", {}).get("maxReplicas", 6)
    cur_r = hpa.get("status", {}).get("currentReplicas", 0)
    des_r = hpa.get("status", {}).get("desiredReplicas", 0)
    c_metrics = hpa.get("status", {}).get("currentMetrics") or []
    cur_util = "-"
    cur_avg_val = "-"
    for cm in c_metrics:
        if cm.get("type") == "Resource" and cm.get("resource", {}).get("name") == "cpu":
            cur = cm["resource"].get("current", {})
            if "averageUtilization" in cur:
                cur_util = f"{cur['averageUtilization']}%"
            if "averageValue" in cur:
                cur_avg_val = cur["averageValue"]
    load_mode = load_dep.get("data", {}).get("mode", "baseline")
    load_active = (load_mode == "spike")
    load_str = f"{MAGENTA}SPIKE (high CPU demand){RESET}" if load_active else f"{GREEN}BASELINE (steady ~80m){RESET}"
    rep_color = MAGENTA if des_r > min_r else GREEN
    print(
        f"  HPA Status: Replicas={rep_color}{BOLD}{cur_r}/{des_r}{RESET} (min={min_r}, max={max_r}) | "
        f"CPU Utilization={YELLOW}{cur_util}{RESET} / 60% target (avg={cur_avg_val}) | Load={load_str}\n"
    )

# Section 2: rightsized-api Pods
print(f"{BOLD}[2] rightsized-api Pods (In-Place CPU Rightsizing & Live Cgroup Quota){RESET}")
if not pods:
    print(f"  {YELLOW}No rightsized-api Pods found{RESET}\n")
else:
    header = f"  {'POD':<34} {'READY':<6} {'RESTARTS':<8} {'SPEC-REQ/LIM':<14} {'BOOT-CGROUP':<12} {'LIVE-CGROUP':<12} {'LIVE-USAGE':<10} {'BOOST-ANNOTATION'}"
    print(f"{DIM}{header}{RESET}")
    for p in sorted(pods, key=lambda x: x["metadata"]["name"]):
        pname = p["metadata"]["name"]
        conds = {c["type"]: c["status"] for c in p.get("status", {}).get("conditions", [])}
        ready = conds.get("Ready") == "True"
        ready_col = f"{GREEN}{'True':<6}{RESET}" if ready else f"{YELLOW}{'False':<6}{RESET}"
        c_specs = p.get("spec", {}).get("containers", [{}])
        s_req = norm_cpu(c_specs[0].get("resources", {}).get("requests", {}).get("cpu", "-"))
        s_lim = norm_cpu(c_specs[0].get("resources", {}).get("limits", {}).get("cpu", "-"))
        spec_str = f"{s_req}/{s_lim}"
        c_stats = p.get("status", {}).get("containerStatuses", [{}])
        restarts = c_stats[0].get("restartCount", 0) if c_stats else 0
        anns = p["metadata"].get("annotations", {})
        has_boost = ("vpaCPUStartupBoost/app" in anns) or ("vpaCpuStartupBoost/app" in anns)
        boost_str = f"{MAGENTA}boosting (1000m){RESET}" if has_boost else f"{GREEN}unboosted/steady{RESET}"

        rep = reports.get(pname, {})
        boot_c = rep.get("BOOT_CPU_MAX_MC", "-")
        live_c = rep.get("LIVE_CPU_MAX_MC", "-")
        usage_c = rep.get("LIVE_USAGE_MC", "-")

        spec_col = f"{MAGENTA}{spec_str:<14}{RESET}" if s_req == "1000m" else f"{GREEN}{spec_str:<14}{RESET}"
        print(f"  {pname:<34} {ready_col} {str(restarts):<8} {spec_col} {boot_c:<12} {live_c:<12} {usage_c:<10} {boost_str}")
    print()

# Section 3: VPA In-Place Resize & HPA Scaling Events
print(f"{BOLD}[3] Recent VPA & HPA Scaling Events (InPlaceResizedByVPA / SuccessfulRescale){RESET}")
rel_events = [e for e in events if e.get("reason") in ("InPlaceResizedByVPA", "SuccessfulRescale")]
if not rel_events:
    print(f"  {YELLOW}Waiting for VPA in-place resize or HPA rescale events...{RESET}")
else:
    for e in rel_events[-6:]:
        ts = e.get("lastTimestamp") or e.get("eventTime") or e.get("metadata", {}).get("creationTimestamp", "")
        reason = e.get("reason", "")
        obj = e.get("involvedObject", {}).get("name", "")
        msg = e.get("message", "")
        r_col = f"{GREEN}{reason}{RESET}" if reason == "InPlaceResizedByVPA" else f"{MAGENTA}{reason}{RESET}"
        print(f"  • [{ts}] {r_col} ({BOLD}{obj}{RESET}): {msg}")
PY
}

if [[ "${ONCE}" == "true" ]]; then
  render_snapshot
  exit 0
fi

while true; do
  out="$(render_snapshot)"
  printf '\033[H\033[2J%s\n' "${out}"
  sleep "${WATCH_INTERVAL}"
done
