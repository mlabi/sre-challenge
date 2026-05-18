# Trivy — security scan cheatsheet

Trivy is the one-binary scanner for IaC (Ansible playbooks, Helm,
Kubernetes manifests, Dockerfiles) and container images. This doc
shows how to run it against this repo and how to interpret the
output.

## Install

```bash
brew install trivy        # macOS
# or
sudo apt-get install trivy
trivy --version
```

## Quick start — scan the whole repo

```bash
# Everything: K8s manifests + Helm chart + Dockerfiles
trivy config .

# Only HIGH and CRITICAL (cuts noise on first read)
trivy config --severity HIGH,CRITICAL .

# Repo is clean if this exits 0:
trivy config --severity HIGH,CRITICAL --exit-code 1 .
```

`trivy config` walks the directory, recognises every supported config
type, and runs the right rule set against each. Output groups findings
by file, with rule ID, severity, the offending lines, and a link to
the explanation in https://avd.aquasec.com/.

## Generate a markdown report

The repo has a Make target that runs Trivy and writes a dated report
into `doc/reports/`:

```bash
make trivy-report
# → doc/reports/trivy-2026-05-18.md
```

The report contains a grouped summary, full HIGH/CRITICAL output, and
the Trivy version used. Drop it into a PR description or share it
with the team.

## Scan a specific target

```bash
trivy config k8s/                              # raw K8s YAML only
trivy config charts/app/                       # renders Helm + scans
trivy config deploy/ansible/                   # Ansible playbooks
trivy config docker/Dockerfile                 # one Dockerfile
trivy config app/back/src/main/docker/Dockerfile
```

## Scan a built image (after the Jenkins pipeline pushes it)

The internal registry uses the lab CA. Either pass `--cacert` or
import the CA into the Docker / Trivy trust store first.

```bash
# Extract the lab CA once
kubectl -n cert-manager get secret lab-ca-secret \
  -o 'jsonpath={.data.ca\.crt}' | base64 -d > /tmp/lab-ca.crt

# Scan the image (TLS via lab CA)
SSL_CERT_FILE=/tmp/lab-ca.crt \
  trivy image registry.192.168.10.51.nip.io/back:latest

# Only OS package CVEs above a threshold
SSL_CERT_FILE=/tmp/lab-ca.crt \
  trivy image --severity HIGH,CRITICAL --ignore-unfixed \
    registry.192.168.10.51.nip.io/back:latest
```

## Useful filters

```bash
# Only a single rule (useful when triaging)
trivy config --include-checks KSV-0045 .

# JSON for scripting — pipe through jq to group by rule
trivy config --severity HIGH,CRITICAL --format json . \
  | jq -r '[.Results[]? | .Misconfigurations[]?
            | {sev: .Severity, id: .ID, title: .Title}]
           | group_by(.id)
           | map({id: .[0].id, sev: .[0].sev, title: .[0].title, count: length})
           | sort_by(-.count)
           | .[] | "\(.sev)  \(.id)  ×\(.count)  \(.title)"'
```

## `.trivyignore` — documenting accepted findings

Suppress a rule by adding its ID on its own line in `.trivyignore`
(at the repo root). Always put a comment above explaining what the
rule warns about, why we accept it, and the scope.

```bash
# Jenkins-on-k8s pattern: kubernetes plugin needs pods/exec on its
# build namespace to stream agent logs and run inline 'sh' steps.
# Scoped to jenkins-build only.
KSV-0053
```

## How to read a finding

A typical Trivy entry:

```
KSV-0045 (CRITICAL): Role 'deployer' should not use verb '*'
════════════════════════════════════════
Using a wildcard verb grants any current and future verbs that exist
on the listed resources, including 'bind' and 'escalate'.

See https://avd.aquasec.com/misconfig/ksv-0045
────────────────────────────────────────
 k8s/jenkins/rbac-app-namespaces.yaml:45-47
────────────────────────────────────────
  45 ┌   - apiGroups: ["apps"]
  46 │     resources: ["deployments","replicasets","statefulsets"]
  47 └     verbs: ["*"]
────────────────────────────────────────
```

Three things to extract:
- **Rule ID** (`KSV-0045`) — link to the catalog: https://avd.aquasec.com/misconfig/ksv-0045
- **Severity** — CRITICAL/HIGH should be triaged first; MEDIUM/LOW often
  acceptable for non-prod workloads.
- **Location** — file + line range, fix in place.

## Triage workflow

1. **Group by rule** (the `jq` snippet above) — many findings often
   collapse into one fix in a shared template.
2. For each group, ask:
   - *Must-fix*: privilege escalation, hostPath, no securityContext,
     wildcard verbs, missing limits/requests.
   - *Should-fix*: `:latest` tags, no liveness/readiness probes,
     public images without digest.
   - *Accept with reason*: things the architecture genuinely requires.
     Add to `.trivyignore` with the comment.
3. Fix or accept everything HIGH/CRITICAL before merging.
4. Re-run `make trivy-report` until clean.

## Common rule IDs you'll see in this repo

| ID | What it flags | Typical fix |
|---|---|---|
| `KSV-0045` | wildcard verbs in Role/ClusterRole | enumerate verbs explicitly |
| `KSV-0056` | Role can manage Service/Ingress/NP | accept if namespace-scoped + helm needs it |
| `KSV-0053` | `pods/exec` in Role | accept for Jenkins build-agent SA |
| `KSV-0048` | RBAC over workloads | typically helm deployer Role — accept |
| `KSV-0014` | container runs as root | set `runAsNonRoot: true` + `runAsUser: <UID>` |
| `KSV-0118` | default ServiceAccount used | give the workload its own SA |
| `DS-0002` | Dockerfile missing `USER` | add `USER 1000` before `ENTRYPOINT` |

Full catalog: https://avd.aquasec.com/misconfig/

## CI gate (Jenkins pipeline)

Drop a stage like this into `Jenkinsfile` so a HIGH/CRITICAL finding
ever showing up fails the build:

```groovy
stage('Trivy IaC scan') {
    steps {
        container('tools') {
            sh '''
                trivy config \
                    --severity HIGH,CRITICAL \
                    --exit-code 1 \
                    --skip-dirs 'deploy/ansible/.ansible_facts_cache,node_modules' \
                    .
            '''
        }
    }
}
```

`--exit-code 1` makes Trivy exit non-zero when any finding at the
listed severity is present, which fails the CI stage.
