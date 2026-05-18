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

## My deployment

k3s on **Ubuntu 26.04 LTS**. The same playbooks work with one node or many —
add hosts to `deploy/ansible/inventory/hosts.yml` and `make all` figures the
rest out (control-plane IP, ingress hostname, NetworkPolicy CIDRs are derived
from the inventory, not hard-coded).

In addition to Kafka and Postgres I run:

- **HashiCorp Vault** as the single source of truth for credentials
  (Jenkins admin, Postgres app user, internal registry htpasswd). Workloads
  never touch Vault directly — External Secrets Operator materializes
  `Secret` objects in the consuming namespace.
- **Jenkins** as the CI/CD plane. Controller runs with zero executors and
  a frozen plugin set; build jobs spawn ephemeral kaniko pods that build
  the three Spring Boot images and push them to an in-cluster registry,
  then helm-upgrade them into `demo-front/back/reader`, then run an
  end-to-end smoke test.

### Install

```bash
make all                  # bring up k3s + Vault + ESO + Kafka + Postgres + registry + Jenkins
make creds                # print Jenkins admin URL + password
make ci-deploy            # trigger the pipeline (builds + deploys + smoke)
```

### Smoke test from your workstation

The pipeline already runs a smoke test from inside the cluster. To repeat it
from the outside (POST through the ingress, GET back from the reader, assert
the message round-tripped through Kafka and Postgres):

```bash
make smoke
```

`FRONT_URL` and `READER_URL` are derived from `ingress_base_domain` in
`group_vars/all.yml`. Override per call if needed:

```bash
FRONT_URL=https://front.192.168.10.51.nip.io \
READER_URL=https://reader.192.168.10.51.nip.io \
  make smoke
```

### Wipe

```bash
make wipe CONFIRM=YES     # uninstall k3s on every inventory node + clear local artifacts
```
