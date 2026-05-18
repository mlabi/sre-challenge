# Trivy — security scan cheatsheet

Trivy is the one-binary scanner for IaC (Terraform, Helm, Kubernetes,
Dockerfile) and container images. This doc shows how to run it against
this repo and how to interpret the output.

## Install

```bash
brew install trivy        # macOS
# or
sudo apt-get install trivy
trivy --version
```

## Quick start — scan the whole repo

```bash
# Everything: K8s manifests + Helm chart + Terraform + Dockerfiles
trivy config .

# Only HIGH and CRITICAL (cuts noise on first read)
trivy config --severity HIGH,CRITICAL .

# Repo is clean if this prints nothing actionable:
trivy config --severity HIGH,CRITICAL --exit-code 1 .
```

`trivy config` walks the directory, recognises every supported config
type, and runs the right rule set against each. Output groups findings
by file, with rule ID, severity, the offending lines, and a link to the
explanation in https://avd.aquasec.com/.

## Scan a specific target

```bash
trivy config k8s/                              # raw K8s YAML only
trivy config charts/app/                       # renders Helm + scans
trivy config deploy/terraform/                 # Terraform IaC only
trivy config docker/Dockerfile                 # one Dockerfile
trivy config app/back/src/main/docker/Dockerfile
```

## Scan a built image

```bash
# After Jenkins pushed the image to Artifact Registry
gcloud auth configure-docker europe-central2-docker.pkg.dev --quiet

trivy image \
  europe-central2-docker.pkg.dev/sre-challenge-mlabi-1779024830/sre-challenge/back:latest

# Only OS package CVEs above a threshold
trivy image --severity HIGH,CRITICAL --ignore-unfixed \
  europe-central2-docker.pkg.dev/.../back:latest
```

## Useful filters

```bash
# Only a single rule (useful when triaging)
trivy config --include-checks KSV-0045 .

# Skip rules we've accepted (see .trivyignore)
trivy config --skip-files .trivyignore .

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

This repo has a top-level `.trivyignore` that suppresses rules we have
consciously accepted (Jenkins-on-k8s `pods/exec`, namespace-scoped
Service/Ingress reconcile by the deployer Role, etc.). Every entry has
a one-line reason inline — never add an ID without explaining why.

```bash
cat .trivyignore
```

If you add a new exception:
1. Put the rule ID on its own line.
2. Add a comment above with: what the rule warns about, why we accept it,
   and the scope ("only in jenkins-build", "namespace-scoped Role only").

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
     wildcard verbs, public-internet egress without justification.
   - *Should-fix*: missing resource limits/requests, `:latest` tags,
     no liveness/readiness probes, public images without digest.
   - *Accept with reason*: things the architecture genuinely requires.
     Add to `.trivyignore` with the comment.
3. Fix or accept everything HIGH/CRITICAL before merging.
4. Re-run `trivy config --severity HIGH,CRITICAL .` until clean.

## Common rule IDs you'll see in this repo

| ID | What it flags | Typical fix |
|---|---|---|
| `KSV-0045` | wildcard verbs in Role/ClusterRole | enumerate verbs explicitly |
| `KSV-0056` | Role can manage Service/Ingress/NP | accept if namespace-scoped + helm needs it |
| `KSV-0053` | `pods/exec` in Role | accept for Jenkins build-agent SA |
| `KSV-0048` | RBAC over workloads | typically helm deployer Role — accept |
| `KSV-0113` | Role can manage Secrets | accept if scoped to one namespace |
| `KSV-0014` | container runs as root | set `runAsNonRoot: true` + `runAsUser: <UID>` |
| `KSV-0118` | default ServiceAccount used | give the workload its own SA |
| `DS-0002` | Dockerfile missing `USER` | add `USER 1000` before `ENTRYPOINT` |
| `GCP-0048` | legacy GCE metadata endpoints | `metadata.disable-legacy-endpoints = "true"` on node pool |
| `GCP-0076` | VPC subnet flow logs off | enable `log_config {}` on the subnetwork |

Full catalog: https://avd.aquasec.com/misconfig/

## CI gate (Jenkins / GitHub Actions)

Drop this into the pipeline so a HIGH/CRITICAL ever showing up fails
the build:

```bash
trivy config \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  --skip-dirs '.terraform,node_modules' \
  .
```

`--exit-code 1` makes Trivy exit non-zero when any finding at the listed
severity is present, which fails the CI stage.
