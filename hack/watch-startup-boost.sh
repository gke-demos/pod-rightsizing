#!/usr/bin/env bash
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
NAMESPACE="${NAMESPACE:-pod-rightsizing}"
VPA_NAME="${VPA_NAME:-boosted-app-vpa}"
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
  local vpa_json pods_json events_json
  vpa_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get vpa "${VPA_NAME}" -o json 2>/dev/null || echo "{}")"
  pods_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l demo=startup-boost -o json 2>/dev/null || echo '{"items":[]}')"
  events_json="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get events -o json 2>/dev/null || echo '{"items":[]}')"

  local reports_raw=""
  local pod_names
  pod_names="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods -l demo=startup-boost --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  for p in ${pod_names}; do
    local rep
    rep="$(kubectl --context="${KUBE_CONTEXT}" -n "${NAMESPACE}" exec "${p}" -- cat /tmp/rightsizing-report 2>/dev/null || true)"
    if [[ -n "${rep}" ]]; then
      reports_raw+="__POD_REPORT_START__:${p}"$'\n'"${rep}"$'\n'"__POD_REPORT_END__"$'\n'
    fi
  done

  python3 - "${KUBE_CONTEXT}" "${NAMESPACE}" "${vpa_json}" "${pods_json}" "${events_json}" "${reports_raw}" <<'PY'
import datetime
import json
import sys

ctx = sys.argv[1]
ns = sys.argv[2]
vpa = json.loads(sys.argv[3] or "{}")
pods = json.loads(sys.argv[4] or '{"items":[]}').get("items", [])
events = json.loads(sys.argv[5] or '{"items":[]}').get("items", [])
reports_raw = sys.argv[6]

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
print(f"{BOLD}{CYAN}=== GKE 1.37 VPA CPU Startup Boost & In-Place Unboost Observer ({now_utc}) ==={RESET}")
print(f"{DIM}Namespace: {ns} | VPA: VerticalPodAutoscaler/boosted-app-vpa{RESET}\n")

# Section 1: VPA Startup Boost Policy
print(f"{BOLD}[1] VPA Startup Boost Policy (VerticalPodAutoscaler/boosted-app-vpa){RESET}")
if not vpa or "spec" not in vpa:
    print(f"  {RED}VerticalPodAutoscaler/boosted-app-vpa not found{RESET}\n")
else:
    spec = vpa.get("spec", {})
    target = spec.get("targetRef", {})
    up_mode = spec.get("updatePolicy", {}).get("updateMode", "Unknown")
    sb_cpu = spec.get("startupBoost", {}).get("cpu", {})
    sb_type = sb_cpu.get("type", "None")
    sb_val = sb_cpu.get("factor", sb_cpu.get("quantity", "-"))
    sb_dur = sb_cpu.get("durationSeconds", 0)
    c_pols = spec.get("resourcePolicy", {}).get("containerPolicies", [])
    ctrl_vals = c_pols[0].get("controlledValues", "RequestsAndLimits") if c_pols else "RequestsAndLimits"
    recs = vpa.get("status", {}).get("recommendation", {}).get("containerRecommendations", [])
    rec_target = norm_cpu(recs[0].get("target", {}).get("cpu", "-")) if recs else "pending"
    print(
        f"  Target: {BOLD}{target.get('kind','Deployment')}/{target.get('name','boosted-app')}{RESET} | "
        f"updateMode: {GREEN}{up_mode}{RESET} | "
        f"controlledValues: {CYAN}{ctrl_vals}{RESET}"
    )
    print(
        f"  startupBoost.cpu: type={MAGENTA}{sb_type}{RESET}, factor={MAGENTA}{sb_val}x{RESET}, "
        f"durationSeconds={GREEN}{sb_dur}s{RESET} | VPA Target CPU: {YELLOW}{rec_target}{RESET}\n"
    )

# Section 2: Pod CPU Allocation & Admission Annotations
print(f"{BOLD}[2] Pod CPU Allocation, Readiness & Startup Boost Annotation{RESET}")
if not pods:
    print(f"  {YELLOW}No startup-boost demo Pods found{RESET}\n")
else:
    header = f"  {'POD':<30} {'ROLE':<9} {'READY':<6} {'RESTARTS':<8} {'SPEC-REQ/LIM':<14} {'STATUS-ACT':<11} {'BOOST-ANNOTATION (vpaCPUStartupBoost/app)'}"
    print(f"{DIM}{header}{RESET}")
    for p in sorted(pods, key=lambda x: x["metadata"].get("labels", {}).get("role", ""), reverse=True):
        pname = p["metadata"]["name"]
        role = p["metadata"].get("labels", {}).get("role", "-")
        anns = p["metadata"].get("annotations", {})
        boost_ann_raw = anns.get("vpaCPUStartupBoost/app") or anns.get("vpaCpuStartupBoost/app") or ""
        if boost_ann_raw:
            try:
                ba = json.loads(boost_ann_raw)
                b_req = ba.get("requests", {}).get("cpu", "?")
                b_lim = ba.get("limits", {}).get("cpu", "?")
                boost_ann = f"{MAGENTA}active (base={b_req}/{b_lim}){RESET}"
            except Exception:
                boost_ann = f"{MAGENTA}present{RESET}"
        else:
            boost_ann = f"{DIM}<none / cleared>{RESET}" if role == "boosted" else f"{DIM}<unboosted control>{RESET}"

        conds = {c["type"]: c["status"] for c in p.get("status", {}).get("conditions", [])}
        ready = conds.get("Ready") == "True"
        ready_col = f"{GREEN}{'True':<6}{RESET}" if ready else f"{YELLOW}{'False':<6}{RESET}"

        c_specs = p.get("spec", {}).get("containers", [{}])
        s_req = norm_cpu(c_specs[0].get("resources", {}).get("requests", {}).get("cpu", "-"))
        s_lim = norm_cpu(c_specs[0].get("resources", {}).get("limits", {}).get("cpu", "-"))
        spec_str = f"{s_req}/{s_lim}"

        c_stats = p.get("status", {}).get("containerStatuses", [{}])
        restarts = c_stats[0].get("restartCount", 0) if c_stats else 0
        alloc_cpu = norm_cpu(c_stats[0].get("allocatedResources", {}).get("cpu") or c_stats[0].get("resources", {}).get("requests", {}).get("cpu") or s_req)

        if s_req == "1000m":
            spec_col = f"{MAGENTA}{spec_str:<14}{RESET}"
        elif s_req == "250m" and role == "boosted":
            spec_col = f"{GREEN}{spec_str:<14}{RESET}"
        else:
            spec_col = f"{YELLOW}{spec_str:<14}{RESET}"

        role_col = f"{CYAN}{role:<9}{RESET}" if role == "boosted" else f"{YELLOW}{role:<9}{RESET}"
        print(f"  {pname:<30} {role_col} {ready_col} {str(restarts):<8} {spec_col} {alloc_cpu:<11} {boost_ann}")
    print()

# Section 3: Live Container Cgroup v2 Telemetry & Cold-Start Comparison
print(f"{BOLD}[3] Live Container Cgroup v2 Telemetry (/sys/fs/cgroup/cpu.max & cpu.stat){RESET}")
if not reports:
    print(f"  {YELLOW}Waiting for containers to complete initialization and write /tmp/rightsizing-report...{RESET}\n")
else:
    header = f"  {'POD':<30} {'ROLE':<9} {'BOOT-CGROUP':<12} {'LIVE-CGROUP':<12} {'STARTUP-MS':<11} {'NR-THROTTLED':<13} {'THROTTLED-MS'}"
    print(f"{DIM}{header}{RESET}")
    throttled_ms_val = None
    boosted_ms_val = None
    throttled_cnt_val = None
    boosted_cnt_val = None

    for pname in sorted(reports.keys()):
        rep = reports[pname]
        role = rep.get("APP_ROLE", "-")
        boot_c = rep.get("BOOT_CPU_MAX_MC", "-")
        live_c = rep.get("LIVE_CPU_MAX_MC", "-")
        s_ms = rep.get("STARTUP_MS", "-")
        nr_t = rep.get("STARTUP_NR_THROTTLED", "-")
        t_ms = rep.get("STARTUP_THROTTLED_MS", "-")
        if role == "throttled":
            try:
                throttled_ms_val = int(s_ms)
                throttled_cnt_val = int(nr_t)
            except Exception:
                pass
        elif role == "boosted":
            try:
                boosted_ms_val = int(s_ms)
                boosted_cnt_val = int(nr_t)
            except Exception:
                pass
        live_col = f"{GREEN}{live_c:<12}{RESET}" if (role == "boosted" and live_c == "250m") else (f"{MAGENTA}{live_c:<12}{RESET}" if live_c == "1000m" else f"{YELLOW}{live_c:<12}{RESET}")
        role_col = f"{CYAN}{role:<9}{RESET}" if role == "boosted" else f"{YELLOW}{role:<9}{RESET}"
        print(f"  {pname:<30} {role_col} {boot_c:<12} {live_col} {s_ms + 'ms':<11} {nr_t:<13} {t_ms}ms")

    if throttled_ms_val and boosted_ms_val and boosted_ms_val > 0:
        speedup = throttled_ms_val / boosted_ms_val
        print(
            f"\n  {GREEN}Cold-Start Result:{RESET} boosted-app initialized in {BOLD}{boosted_ms_val}ms{RESET} vs. "
            f"{BOLD}{throttled_ms_val}ms{RESET} ({GREEN}{BOLD}{speedup:.2f}x faster{RESET}, "
            f"CFS throttled periods: {RED}{throttled_cnt_val}{RESET} -> {GREEN}{boosted_cnt_val}{RESET})"
        )
    print()

# Section 4: In-Place VPA Resize Events
print(f"{BOLD}[4] In-Place VPA Resize Events (reason=InPlaceResizedByVPA){RESET}")
vpa_events = [e for e in events if e.get("reason") == "InPlaceResizedByVPA"]
if not vpa_events:
    print(f"  {YELLOW}Waiting for VPA Updater 1-minute cycle to emit InPlaceResizedByVPA event...{RESET}")
else:
    for e in vpa_events[-4:]:
        ts = e.get("lastTimestamp") or e.get("eventTime") or e.get("metadata", {}).get("creationTimestamp", "")
        obj = e.get("involvedObject", {}).get("name", "")
        msg = e.get("message", "")
        print(f"  {GREEN}✓{RESET} [{ts}] {BOLD}{obj}{RESET}: {msg}")
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
