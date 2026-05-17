ANSIBLE_DIR := deploy/ansible
PLAYBOOK    := cd $(ANSIBLE_DIR) && ansible-playbook

GROUP_VARS ?= $(ANSIBLE_DIR)/inventory/group_vars/all.yml
INGRESS_BASE_DOMAIN ?= $(shell awk -F'"' '/^ingress_base_domain:/ {print $$2}' $(GROUP_VARS))
REGISTRY_HOST       ?= registry.$(INGRESS_BASE_DOMAIN)
JENKINS_HOST        ?= jenkins.$(INGRESS_BASE_DOMAIN)
FRONT_HOST          ?= front.$(INGRESS_BASE_DOMAIN)
READER_HOST         ?= reader.$(INGRESS_BASE_DOMAIN)

export REGISTRY FRONT_URL READER_URL
REGISTRY    := $(REGISTRY_HOST)
FRONT_URL   := https://$(FRONT_HOST)
READER_URL  := https://$(READER_HOST)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: collections
collections: ## Install required Ansible collections (one-time on the controller)
	ansible-galaxy collection install community.general ansible.posix

.PHONY: bootstrap
bootstrap: ## Generate USB images for the three boxes (SSH key + cloud-init for box-1/2/3)
	cd $(ANSIBLE_DIR)/bootstrap && ./00-generate-ssh-key.sh
	cd $(ANSIBLE_DIR)/bootstrap/ubuntu && ./generate.sh

.PHONY: ping
ping: ## Ansible reachability check to box-1/2/3
	cd $(ANSIBLE_DIR) && ansible all -m ping

.PHONY: cluster
cluster: ## k3s + base config (10-base, 12-k3s, 13-secrets-encryption, 14-pod-security)
	$(PLAYBOOK) playbooks/10-base.yml
	$(PLAYBOOK) playbooks/12-k3s.yml
	$(PLAYBOOK) playbooks/13-secrets-encryption.yml
	$(PLAYBOOK) playbooks/14-pod-security.yml

.PHONY: infra
infra: ## Infrastructure: ingress, cert-manager, Vault, ESO, operators, NetworkPolicies
	$(PLAYBOOK) playbooks/15-ingress.yml
	$(PLAYBOOK) playbooks/16-cert-manager.yml
	$(PLAYBOOK) playbooks/17-vault.yml
	$(PLAYBOOK) playbooks/18-eso.yml
	$(PLAYBOOK) playbooks/20-operators.yml
	$(PLAYBOOK) playbooks/25-network-policies.yml

.PHONY: apps
apps: ## Data plane + Jenkins: Kafka, Postgres, Jenkins
	$(PLAYBOOK) playbooks/30-infra.yml
	$(PLAYBOOK) playbooks/40-jenkins.yml

.PHONY: all
all: ping cluster infra registry node-trust apps app-secrets ## Full bring-up. Jenkins controller image is built in-cluster by 40-jenkins.yml; app images + deploy come from Jenkins pipeline — run `make ci-trigger` afterwards.

.PHONY: ci-trigger
ci-trigger: ## Trigger the Jenkins 'sre-challenge' pipeline and wait for it to finish (builds 3 apps + deploys + smoke)
	@USER=admin; \
	PASS=$$(KUBECONFIG=$$HOME/.kube/k3s-config kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d); \
	CA=/tmp/lab-ca.crt; \
	BASE=https://$(JENKINS_HOST); \
	JOB=sre-challenge; \
	JAR=/tmp/jenkins-cookies.txt; \
	if [ ! -f $$CA ]; then echo "Missing $$CA (run make infra to extract lab CA)"; exit 1; fi; \
	rm -f $$JAR; \
	echo "==> Trigger $$JOB at $$BASE"; \
	CRUMB=$$(curl -sS --cacert $$CA -u "$$USER:$$PASS" -c $$JAR -b $$JAR "$$BASE/crumbIssuer/api/json" | jq -r '.crumb // empty'); \
	if [ -z "$$CRUMB" ]; then echo "Failed to get CSRF crumb"; exit 1; fi; \
	NEXT=$$(curl -sS --cacert $$CA -u "$$USER:$$PASS" -c $$JAR -b $$JAR "$$BASE/job/$$JOB/api/json" | jq -r '.nextBuildNumber'); \
	echo "    next build: #$$NEXT"; \
	curl -fsS --cacert $$CA -u "$$USER:$$PASS" -c $$JAR -b $$JAR -H "Jenkins-Crumb: $$CRUMB" -X POST "$$BASE/job/$$JOB/build" -o /dev/null; \
	echo "==> Waiting for build #$$NEXT to finish (5s poll, 20 min timeout)"; \
	RESULT=""; \
	for i in $$(seq 1 240); do \
	  sleep 5; \
	  RESULT=$$(curl -sS --cacert $$CA -u "$$USER:$$PASS" "$$BASE/job/$$JOB/$$NEXT/api/json" 2>/dev/null | jq -r '.result // "null"'); \
	  if [ "$$RESULT" != "null" ] && [ -n "$$RESULT" ]; then break; fi; \
	  if [ $$((i % 12)) -eq 0 ]; then echo "    still building (~$$((i*5/60)) min)"; fi; \
	done; \
	rm -f $$JAR; \
	echo "==> Build #$$NEXT result: $$RESULT"; \
	echo "    log: $$BASE/job/$$JOB/$$NEXT/console"; \
	[ "$$RESULT" = "SUCCESS" ]

.PHONY: wipe
wipe: ## DESTRUCTIVE — uninstall k3s on all nodes + remove controller artifacts. Confirm with `make wipe CONFIRM=YES`.
	@if [ "$(CONFIRM)" != "YES" ]; then echo "Refusing to wipe without CONFIRM=YES"; exit 1; fi
	$(PLAYBOOK) playbooks/99-wipe.yml -e confirm=YES

.PHONY: jenkins
jenkins: ## Re-run Jenkins playbook (idempotent; has rescue block for stuck pods)
	$(PLAYBOOK) playbooks/40-jenkins.yml

.PHONY: vault
vault: ## Re-run Vault playbook (idempotent; re-unseals if pod restarted)
	$(PLAYBOOK) playbooks/17-vault.yml

.PHONY: netpol
netpol: ## Re-apply NetworkPolicies
	$(PLAYBOOK) playbooks/25-network-policies.yml

.PHONY: registry
registry: ## Install / update internal image registry (TLS, htpasswd from Vault)
	$(PLAYBOOK) playbooks/45-registry.yml

.PHONY: app-secrets
app-secrets: ## Cross-namespace ExternalSecrets (Kafka certs + registry-pull) for demo-* ns
	$(PLAYBOOK) playbooks/46-app-secrets.yml

.PHONY: node-trust
node-trust: ## Install lab CA into each k3s node's system trust (for image pulls)
	$(PLAYBOOK) playbooks/47-node-trust.yml

.PHONY: deploy-apps
deploy-apps: ## helm install front/back/reader (image.repository + ingress.baseDomain from group_vars)
	KUBECONFIG=$$HOME/.kube/k3s-config helm upgrade --install front charts/app \
		--namespace demo-front -f charts/app/values-front.yaml \
		--set image.repository=$(REGISTRY_HOST)/front \
		--set ingress.baseDomain=$(INGRESS_BASE_DOMAIN) --wait --timeout=3m
	KUBECONFIG=$$HOME/.kube/k3s-config helm upgrade --install back charts/app \
		--namespace demo-back -f charts/app/values-back.yaml \
		--set image.repository=$(REGISTRY_HOST)/back \
		--set ingress.baseDomain=$(INGRESS_BASE_DOMAIN) --wait --timeout=3m
	KUBECONFIG=$$HOME/.kube/k3s-config helm upgrade --install reader charts/app \
		--namespace demo-reader -f charts/app/values-reader.yaml \
		--set image.repository=$(REGISTRY_HOST)/reader \
		--set ingress.baseDomain=$(INGRESS_BASE_DOMAIN) --wait --timeout=3m

.PHONY: smoke
smoke: ## End-to-end smoke test (POST front → wait → GET reader, assert message)
	./docker/smoke-test.sh

.PHONY: undeploy-apps
undeploy-apps: ## helm uninstall front/back/reader (keeps namespaces/secrets)
	-KUBECONFIG=$$HOME/.kube/k3s-config helm uninstall front  -n demo-front
	-KUBECONFIG=$$HOME/.kube/k3s-config helm uninstall back   -n demo-back
	-KUBECONFIG=$$HOME/.kube/k3s-config helm uninstall reader -n demo-reader

.PHONY: creds
creds: ## Print Jenkins admin credentials
	@echo "URL:      https://$(JENKINS_HOST)/"
	@echo "User:     admin"
	@printf "Password: "
	@KUBECONFIG=$$HOME/.kube/k3s-config kubectl -n jenkins get secret jenkins-admin \
		-o jsonpath='{.data.jenkins-admin-password}' | base64 -d
	@echo

.PHONY: vault-token
vault-token: ## Print the Vault root token (controller-local, ~/.vault-lab/init.json)
	@jq -r .root_token $$HOME/.vault-lab/init.json

.PHONY: vault-ui
vault-ui: ## Port-forward Vault UI to https://localhost:8200
	@echo "Vault UI at https://localhost:8200 (use the root token from 'make vault-token')"
	KUBECONFIG=$$HOME/.kube/k3s-config kubectl -n vault port-forward svc/vault 8200:8200

.PHONY: status
status: ## High-level cluster status (nodes, key workloads, externalsecrets)
	@KUBECONFIG=$$HOME/.kube/k3s-config kubectl get nodes
	@echo
	@KUBECONFIG=$$HOME/.kube/k3s-config kubectl get pods -A \
		-l 'app.kubernetes.io/name in (vault,jenkins,external-secrets,ingress-nginx)'
	@echo
	@KUBECONFIG=$$HOME/.kube/k3s-config kubectl get kafka,kafkatopic -n kafka
	@KUBECONFIG=$$HOME/.kube/k3s-config kubectl get cluster.postgresql.cnpg.io -n postgres
	@KUBECONFIG=$$HOME/.kube/k3s-config kubectl get externalsecret -A

.PHONY: jenkins-clean
jenkins-clean: ## Wipe Jenkins state (helm + PVC) — the playbook will reinstall next run
	@read -p "Delete Jenkins release + PVC? [y/N] " ans; [ "$$ans" = "y" ] || exit 1
	-helm uninstall jenkins -n jenkins
	-KUBECONFIG=$$HOME/.kube/k3s-config kubectl -n jenkins delete pvc jenkins --wait

.PHONY: lint
lint: ## Quick sanity: bash syntax + ansible playbook syntax check
	@set -e; for f in $(ANSIBLE_DIR)/bootstrap/*.sh $(ANSIBLE_DIR)/bootstrap/*/*.sh; do \
		bash -n "$$f" && echo "OK  $$f"; \
	done
	@set -e; for p in $(ANSIBLE_DIR)/playbooks/*.yml; do \
		(cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check "$${p#$(ANSIBLE_DIR)/}" >/dev/null) \
			&& echo "OK  $$p"; \
	done

.PHONY: clean-artifacts
clean-artifacts: ## Remove bootstrap-generated artifacts (USB images)
	rm -rf $(ANSIBLE_DIR)/bootstrap/ubuntu/dist
