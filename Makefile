TF_DIR := deploy/terraform
TF     := cd $(TF_DIR) && terraform

KUBECONFIG_PATH := $(HOME)/.kube/gke-config
export KUBECONFIG := $(KUBECONFIG_PATH)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: tf-init
tf-init: ## terraform init (remote state in GCS — bucket from backend.hcl)
	$(TF) init -backend-config=backend.hcl

.PHONY: tf-fmt
tf-fmt: ## terraform fmt -recursive (canonical .tf style)
	$(TF) fmt -recursive

.PHONY: tf-validate
tf-validate: ## terraform validate (config syntax + semantics)
	$(TF) validate

.PHONY: tf-plan
tf-plan: ## terraform plan
	$(TF) plan

.PHONY: tf-apply
tf-apply: ## terraform apply (creates VPC + KMS + AR + GKE; ~10-12 min first run)
	$(TF) apply

.PHONY: tf-destroy
tf-destroy: ## DESTRUCTIVE — terraform destroy
	$(TF) destroy

.PHONY: tf-output
tf-output: ## Print Terraform outputs
	$(TF) output

.PHONY: kubeconfig
kubeconfig: ## Fetch GKE kubeconfig into ~/.kube/gke-config
	@PROJECT=$$($(TF) output -raw project_id) ; \
	CLUSTER=$$($(TF) output -raw cluster_name) ; \
	LOCATION=$$($(TF) output -raw cluster_location) ; \
	KUBECONFIG=$(KUBECONFIG_PATH) gcloud container clusters get-credentials \
	  $$CLUSTER --zone $$LOCATION --project $$PROJECT
	@kubectl get nodes

.PHONY: bootstrap
bootstrap: cert-manager ingress eso operators jenkins app-secrets ## Full k8s layer (cert-manager, ingress, ESO, operators, Jenkins, app-secrets)

.PHONY: cert-manager
cert-manager: ## Install cert-manager + Let's Encrypt ClusterIssuer
	./deploy/k8s-bootstrap/01-cert-manager.sh

.PHONY: ingress
ingress: ## Install ingress-nginx (LoadBalancer Service)
	./deploy/k8s-bootstrap/02-ingress-nginx.sh

.PHONY: eso
eso: ## Install ESO + ClusterSecretStore (GCP Secret Manager via Workload Identity)
	./deploy/k8s-bootstrap/03-eso.sh

.PHONY: operators
operators: ## Install Strimzi + CNPG + Kafka/Postgres CRs
	./deploy/k8s-bootstrap/04-operators.sh

.PHONY: jenkins
jenkins: ## Install Jenkins (helm) + pre-bake controller image via Cloud Build + JCasC seed
	./deploy/k8s-bootstrap/05-jenkins.sh

.PHONY: app-secrets
app-secrets: ## Cross-namespace ExternalSecrets (Kafka, Postgres) for demo-* ns
	./deploy/k8s-bootstrap/06-app-secrets.sh

.PHONY: all
all: tf-apply kubeconfig bootstrap ## Full bring-up — terraform + kubeconfig + bootstrap. After: `make ci-deploy`

.PHONY: ci-trigger
ci-trigger: ## Trigger Jenkins pipeline and wait for completion
	@USER=admin ; \
	PASS=$$(kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d) ; \
	BASE=$$(kubectl -n jenkins get ingress jenkins -o jsonpath='https://{.spec.rules[0].host}') ; \
	JOB=sre-challenge ; \
	JAR=/tmp/jenkins-cookies.txt ; \
	rm -f $$JAR ; \
	CRUMB=$$(curl -sS -u "$$USER:$$PASS" -c $$JAR -b $$JAR "$$BASE/crumbIssuer/api/json" | jq -r '.crumb // empty') ; \
	[ -n "$$CRUMB" ] || { echo "Failed to get CSRF crumb"; exit 1; } ; \
	NEXT=$$(curl -sS -u "$$USER:$$PASS" -c $$JAR -b $$JAR "$$BASE/job/$$JOB/api/json" | jq -r '.nextBuildNumber') ; \
	echo "Triggering build #$$NEXT at $$BASE" ; \
	curl -fsS -u "$$USER:$$PASS" -c $$JAR -b $$JAR -H "Jenkins-Crumb: $$CRUMB" -X POST "$$BASE/job/$$JOB/build" -o /dev/null ; \
	for i in $$(seq 1 240); do \
	  sleep 5 ; \
	  RESULT=$$(curl -sS -u "$$USER:$$PASS" "$$BASE/job/$$JOB/$$NEXT/api/json" 2>/dev/null | jq -r '.result // "null"' 2>/dev/null) ; \
	  [ -z "$$RESULT" ] && RESULT=null ; \
	  if [ "$$RESULT" != "null" ]; then break ; fi ; \
	  if [ $$((i % 12)) -eq 0 ]; then echo "  still building (~$$((i*5/60)) min)" ; fi ; \
	done ; \
	rm -f $$JAR ; \
	echo "Build #$$NEXT result: $$RESULT  (log: $$BASE/job/$$JOB/$$NEXT/console)" ; \
	[ "$$RESULT" = "SUCCESS" ]

.PHONY: ci-deploy
ci-deploy: ci-trigger ## Alias for ci-trigger

.PHONY: creds
creds: ## Print Jenkins admin URL + password
	@echo "URL:      https://$$(kubectl -n jenkins get ingress jenkins -o jsonpath='{.spec.rules[0].host}')/"
	@echo "User:     admin"
	@printf "Password: "
	@kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
	@echo

.PHONY: status
status: ## High-level cluster status
	@kubectl get nodes
	@kubectl get pods -A -l 'app.kubernetes.io/name in (jenkins,external-secrets,ingress-nginx,cert-manager)'
	@kubectl get kafka,kafkatopic -n kafka 2>/dev/null
	@kubectl get cluster.postgresql.cnpg.io -n postgres 2>/dev/null
	@kubectl get externalsecret -A 2>/dev/null

.PHONY: smoke
smoke: ## End-to-end smoke from controller (POST front → GET reader)
	@INGRESS_IP=$$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}') ; \
	FRONT_URL=https://front.$$INGRESS_IP.nip.io \
	READER_URL=https://reader.$$INGRESS_IP.nip.io \
	SKIP_CA_CHECK=1 \
	  bash docker/smoke-test.sh

.PHONY: destroy
destroy: ## DESTRUCTIVE — helm uninstall + terraform destroy
	-helm uninstall jenkins -n jenkins --wait --timeout=2m 2>/dev/null
	-helm uninstall ingress-nginx -n ingress-nginx --wait --timeout=2m 2>/dev/null
	-helm uninstall external-secrets -n external-secrets --wait --timeout=2m 2>/dev/null
	-helm uninstall cert-manager -n cert-manager --wait --timeout=2m 2>/dev/null
	$(TF) destroy
