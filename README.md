# SRE Coding Challenge

You are tasked with deploying a solution to the Kubernetes cluster. You may use Minikube, Microk8s, k3s or any other Kubernetes distribution.
Solution consists of three SpringBoot applications, Kafka deployment to support messaging and PostgreSQL database to provide a persistence layer.
Application deployment should use helm (https://helm.sh/), Kafka and Postgres may be deployed with any technology you like.

We do not expect too much automation (a few bash scripts should work just fine). In case you prefer to automate everything,
you may use any flavor of automation tools, Ansible, Terraform – everything will work. You may even set up a CI / CD flow using Jenkins/Tekton/Drone/etc. ;)

## Overall architecture

![Overall architecture](doc/img/application-architecture.png)

## Deployment layout

![Deployment layout](doc/img/deployment-layout.png)

## Kafka Topic specs

- name: testCommand
- partitions: 32
- replication-factor: 1

## Database

Application developed with PostgreSQL 16+

Database schema created with Back application first run

## Applications

### Build applications

You need Java 21+ installed, then run

`./gradlew clean build`

to build applications. Jar files will land in `app/back/build/libs/back-0.1.0.jar` (Back app for instance)

### Hints

Few hints to simplify application deployment.

Docker:
`ENTRYPOINT ["java", "-jar", "/app.jar"]`

SpringBoot additional config arg if needed. Additional config values will override default.
`--spring.config.additional-location=path-to-additional-config`

Health check exposed as
`http://localhost:{management.server.port}/health`

Applications expose API management interface as
`http://localhost:{server.port}/swagger-ui.html`

### Front

Sample application configuration `application.yaml` file

```yaml
server.port: 8080
################### Kafka ##############################
spring:
  kafka:
    bootstrap-servers: -kafka-bootstrap-goes-here-

################### Logging settings ###################
logging:
  level:
    root: WARN
    db.demo: INFO

management.server.port: 8081
```

### Back

Sample application configuration `application.yaml` file

```yaml
spring:
  kafka:
    bootstrap-servers: -kafka-bootstrap-goes-here-
  datasource.url: jdbc:postgresql://localhost:5432/postgres
  datasource.username: -username-
  datasource.password: -password-

management.server.port: 8081
```

Hint:
You may use Spring Boot relaxed binding to pass parameters through environment variables
https://docs.spring.io/spring-boot/reference/features/external-config.html#features.external-config.typesafe-configuration-properties.relaxed-binding

`SPRING_DATASOURCE_USERNAME=postgres`

### Reader

Sample application configuration `application.yaml` file

```yaml
spring:
  datasource.url: jdbc:postgresql://localhost:5432/postgres
  datasource.username: -username-
  datasource.password: -password-

management.server.port: 8081
```

---

## Deploying to GKE (this implementation)

Standalone GKE deploy with Workload Identity, Cloud KMS for etcd + Secret
Manager CMEK, Strimzi Kafka (KRaft), CloudNativePG, ESO for secret sync,
cert-manager + Let's Encrypt, and Jenkins running the build pipeline. The
Terraform state lives in a versioned GCS bucket; KMS resources are
re-imported automatically across destroy/apply cycles.

### Prerequisites (once per workstation)

```bash
brew install terraform kubectl helm jq google-cloud-sdk
gcloud components install gke-gcloud-auth-plugin
gcloud auth login                            # interactive
gcloud auth application-default login        # ADC for Terraform
```

### 1. Bootstrap a fresh GCP project (skip if reusing one)

Creates the project, links billing, enables APIs, provisions the GCS state
bucket (versioned, with native locking), and writes
`deploy/terraform/backend.hcl`.

```bash
./deploy/bootstrap-gcp/00-create-project.sh
```

### 2. Fill in `deploy/terraform/terraform.tfvars` (gitignored)

```hcl
project_id = "your-project-id-from-step-1"
region     = "europe-central2"
zone       = "europe-central2-a"
```

### 3. Provision infrastructure

```bash
make tf-init        # once, after backend.hcl exists
make tf-apply       # VPC + KMS + GKE + Artifact Registry + IAM (~12 min first run)
```

`tf-apply` runs `deploy/terraform/import-existing.sh` first, which
re-imports the KMS keyring and crypto keys if they survived a previous
`tf-destroy` (Cloud KMS resources are immutable in GCP and never truly
deleted), and restores any crypto-key versions left in
`DESTROY_SCHEDULED` back to `ENABLED`. The next apply then completes
cleanly instead of 409-ing on the keyring.

### 4. Fetch the kubeconfig

```bash
make kubeconfig     # writes ~/.kube/gke-config
```

The kubeconfig lands in a dedicated file (not your default
`~/.kube/config`), so every Make target in this repo already exports
`KUBECONFIG=~/.kube/gke-config` for you. For ad-hoc `kubectl` /
`helm` calls in the same shell:

```bash
export KUBECONFIG=~/.kube/gke-config
kubectl get nodes
```

### 5. Bootstrap the cluster layer

cert-manager + Let's Encrypt ClusterIssuer, ingress-nginx, ESO with the
GCP Secret Manager provider, Strimzi + CNPG operators with their Kafka /
Postgres clusters, NetworkPolicies for every managed namespace, Jenkins
(pre-baked image via Cloud Build, JCasC seed), and the app-level
ExternalSecrets.

```bash
ACME_EMAIL=you@yourdomain.tld make bootstrap
# If ACME_EMAIL is unset, 01-cert-manager.sh prompts for it interactively.
```

### 6. Build, push, deploy, smoke

`make bootstrap` seeds the Jenkins job and the **first build kicks off
automatically** as soon as the controller is up — `gradle build` →
kaniko push to Artifact Registry → `helm upgrade --install` for each
of the three apps → in-cluster smoke (`POST` to front, then `GET` from
reader and assert the message landed).

```bash
make creds          # Jenkins admin URL + password (paste into a browser)
```

If for some reason the auto-trigger doesn't fire (controller still
warming up, plugin install retried, …) start it by hand:

```bash
make ci-deploy      # triggers the Jenkins pipeline and waits for the result
```

### One-shot bring-up

```bash
ACME_EMAIL=you@yourdomain.tld make all   # = tf-apply + kubeconfig + bootstrap
make creds                               # Jenkins URL + admin password
# first build auto-triggers; if not, fall back to:
make ci-deploy                           # trigger the pipeline manually
```

### Useful sub-targets

```bash
make status         # nodes, pods per namespace, certificates, ingress IP
make creds          # Jenkins URL + admin password
make smoke          # run the smoke test from the workstation
make tf-output      # all Terraform outputs (project_id, registry URL, etc.)
```

### Tearing down

```bash
make tf-destroy     # infra only — KMS keyring + Secret Manager entries are retained
make destroy        # helm uninstall everything first, then tf-destroy
```

The next `make tf-apply` re-imports the leftover KMS resources via
`import-existing.sh`, so destroy → apply round-trips without manual
state surgery.

### Repository layout

```
.
├── app/                          Original challenge applications (Spring Boot 3)
│   ├── front/  back/  reader/    Three Kotlin services (gradle multi-module)
│   └── common/                   Shared message model
├── docker/
│   ├── Dockerfile                Distroless image used by the pipeline
│   ├── Dockerfile.jenkins        Pre-baked Jenkins controller image (Cloud Build)
│   ├── plugins.txt               Pinned Jenkins plugin set
│   └── smoke-test.sh             End-to-end smoke (POST front → GET reader)
├── charts/app/                   Generic Helm chart all three apps share
│   ├── templates/                Deployment / Service / Ingress / NP / ESO
│   └── values-{front,back,reader}.yaml
├── k8s/                          Static manifests applied by the bootstrap scripts
│   ├── namespaces.yaml           Managed ns + PSS labels
│   ├── quotas.yaml               LimitRange + ResourceQuota
│   ├── network-policies/         Per-component NPs (baseline + per-ns allows)
│   ├── kafka/                    Strimzi Kafka cluster + KafkaUser/Topic
│   ├── postgres/                 CNPG Cluster
│   ├── eso/                      ClusterSecretStore + ExternalSecrets (GCP SM)
│   ├── cert-manager/             ClusterIssuer (Let's Encrypt)
│   ├── jenkins/                  RBAC (deployer per demo-* ns, build-agent SA)
│   └── pod-security/             PSS labels for operator namespaces
├── deploy/
│   ├── bootstrap-gcp/
│   │   └── 00-create-project.sh  Creates GCP project, enables APIs, writes
│   │                             GCS state bucket + backend.hcl
│   ├── terraform/                VPC / KMS / Artifact Registry / GKE / IAM
│   │   ├── *.tf                  Resource definitions
│   │   ├── backend.hcl           GCS backend config (gitignored, per project)
│   │   ├── terraform.tfvars      project_id / region / zone (gitignored)
│   │   └── import-existing.sh    Re-imports KMS keyring/keys after destroy
│   │                             so the next apply doesn't 409
│   └── k8s-bootstrap/            01-cert-manager → 06-app-secrets
│       └── jenkins-values.yaml.tpl
├── Jenkinsfile                   Declarative pipeline (gradle → kaniko → helm → smoke)
├── Makefile                      All entry points — `make help` lists them
├── doc/
│   ├── img/                      Architecture diagrams (challenge brief)
│   ├── trivy.md                  How to run + interpret Trivy scans
│   └── reports/                  Dated Trivy reports
├── .trivyignore                  Accepted findings, with reason inline
└── .kube-linter.yaml             kube-linter exclude list, with reason inline
```