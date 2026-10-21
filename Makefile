KUBE_CONTEXT ?= $(shell kubectl config current-context 2>/dev/null)
NAMESPACE ?= pod-rightsizing
HPA_NAMESPACE ?= pod-rightsizing-hpa
PREEMPT_NAMESPACE ?= pod-rightsizing-preemption

.PHONY: apply apply-startup-boost apply-vpa-hpa apply-vpa-preemption \
	load-spike stop-load-spike pack-node-batch trigger-resize-preemption \
	watch watch-startup-boost watch-vpa-hpa watch-vpa-preemption \
	status status-startup-boost status-vpa-hpa status-vpa-preemption \
	logs logs-startup-boost logs-vpa-hpa logs-vpa-preemption \
	verify verify-startup-boost verify-vpa-hpa verify-vpa-preemption \
	clean clean-startup-boost clean-vpa-hpa clean-vpa-preemption

apply: apply-startup-boost

apply-startup-boost:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/01-startup-boost/01-vpa-startup-boost.yaml
	sleep 2
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/01-startup-boost/02-workloads.yaml

apply-vpa-hpa:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/02-vpa-hpa-rightsizing/01-vpa-hpa.yaml
	sleep 2
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/02-vpa-hpa-rightsizing/02-workload.yaml

apply-vpa-preemption:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/03-vpa-preemption-utilization/01-priority-vpa.yaml
	sleep 2
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/03-vpa-preemption-utilization/02-serving-workload.yaml

pack-node-batch:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" NAMESPACE="$(PREEMPT_NAMESPACE)" ./hack/preemption-ctl.sh pack

trigger-resize-preemption:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" NAMESPACE="$(PREEMPT_NAMESPACE)" ./hack/preemption-ctl.sh trigger

load-spike:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/02-vpa-hpa-rightsizing/03-load-spike.yaml
	@for p in $$(kubectl --context="$(KUBE_CONTEXT)" -n "$(HPA_NAMESPACE)" get pods -l app=rightsized-api --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
		kubectl --context="$(KUBE_CONTEXT)" -n "$(HPA_NAMESPACE)" exec "$$p" -- sh -c 'echo spike >/tmp/load-mode' 2>/dev/null || true; \
	done

stop-load-spike:
	kubectl --context="$(KUBE_CONTEXT)" -n "$(HPA_NAMESPACE)" create configmap rightsized-api-load --from-literal=mode=baseline -o yaml --dry-run=client | kubectl --context="$(KUBE_CONTEXT)" apply -f -
	@for p in $$(kubectl --context="$(KUBE_CONTEXT)" -n "$(HPA_NAMESPACE)" get pods -l app=rightsized-api --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
		kubectl --context="$(KUBE_CONTEXT)" -n "$(HPA_NAMESPACE)" exec "$$p" -- rm -f /tmp/load-mode 2>/dev/null || true; \
	done

watch: watch-startup-boost

watch-startup-boost:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch-startup-boost.sh

watch-vpa-hpa:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch-vpa-hpa.sh

watch-vpa-preemption:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch-vpa-preemption.sh

status: status-startup-boost

status-startup-boost:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch-startup-boost.sh --once

status-vpa-hpa:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch-vpa-hpa.sh --once

status-vpa-preemption:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch-vpa-preemption.sh --once

logs: logs-startup-boost

logs-startup-boost:
	@kubectl --context="$(KUBE_CONTEXT)" -n "$(NAMESPACE)" logs -l demo=startup-boost --tail=6

logs-vpa-hpa:
	@kubectl --context="$(KUBE_CONTEXT)" -n "$(HPA_NAMESPACE)" logs -l app=rightsized-api --tail=6

logs-vpa-preemption:
	@kubectl --context="$(KUBE_CONTEXT)" -n "$(PREEMPT_NAMESPACE)" logs -l app=serving-api --tail=6

verify: verify-startup-boost

verify-startup-boost:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/verify-startup-boost-e2e.sh

verify-vpa-hpa:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/verify-vpa-hpa-e2e.sh

verify-vpa-preemption:
	@KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/verify-vpa-preemption-e2e.sh

clean: clean-startup-boost clean-vpa-hpa clean-vpa-preemption

clean-startup-boost:
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/01-startup-boost/02-workloads.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/01-startup-boost/01-vpa-startup-boost.yaml --ignore-not-found=true

clean-vpa-hpa:
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/02-vpa-hpa-rightsizing/03-load-spike.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/02-vpa-hpa-rightsizing/02-workload.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/02-vpa-hpa-rightsizing/01-vpa-hpa.yaml --ignore-not-found=true

clean-vpa-preemption:
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/03-vpa-preemption-utilization/03-batch-packers.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/03-vpa-preemption-utilization/02-serving-workload.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/03-vpa-preemption-utilization/01-priority-vpa.yaml --ignore-not-found=true
