# Zero-Restart Pod Rightsizing on GKE 1.37 (`gke-demos/pod-rightsizing`)

Hands-on demo and blog post repository for **Zero-Restart Pod Rightsizing** on GKE 1.37+ using **VPA CPU Startup Boost** (`spec.startupBoost.cpu`), **In-Place Pod Resize** (`spec.updatePolicy.updateMode: "InPlaceOrRecreate"`), **Cooperative VPA + HPA CPU Rightsizing** (`gke.io/autoscaling-hpa-rightsizing-mode: "gke-hpa-rightsizing-mode-policy"`), and **VPA Decision Audit Logging** (`KCP_VPA`).

## Commands

### Demo 01: Cold-Start CPU Boost & In-Place Unboost (`01-startup-boost`)

- **Deploy side-by-side cold-start comparison (`throttled-app` vs. `boosted-app`)**: `make apply` (or `make apply-startup-boost`)
- **Watch cgroup throttling (`nr_throttled`), readiness latency, allocated CPU, `InPlaceResizedByVPA` events, and `RESTARTS: 0` live**: `make watch` (or `make watch-startup-boost`)
- **Inspect current startup boost & in-place resize status once**: `make status` (or `make status-startup-boost`)
- **Run end-to-end startup boost & unboost verification**: `make verify` (or `make verify-startup-boost`)

### Demo 02: Cooperative VPA + HPA CPU Rightsizing (`02-vpa-hpa-rightsizing`)

- **Deploy workload with cooperative VPA (`gke-hpa-rightsizing-mode-policy` + `startupBoost` + `InPlaceOrRecreate`) and CPU HPA**: `make apply-rightsizing`
- **Trigger synthetic CPU load burst (`make burst`) to scale HPA replicas out with 4x faster startup boost while VPA updates CPU recommendations**: `make burst`
- **Watch HPA replicas, VPA recommendations (`Lower Bound` / `Target` / `Upper Bound`), and Pod CPU requests live**: `make watch-rightsizing`
- **Inspect current VPA + HPA rightsizing status once**: `make status-rightsizing`
- **Run end-to-end VPA + HPA rightsizing verification**: `make verify-rightsizing`

### Cleanup & Docs Verification

- **Clean up all demo resources**: `make clean`
- **Verify documentation and demo media assets**: `./hack/test-docs.sh`

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues (`gke-demos/pod-rightsizing`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Uses the five default canonical triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (`GLOSSARY.md` at the repo root and ADRs in `docs/adr/`). See `docs/agents/domain.md`.
