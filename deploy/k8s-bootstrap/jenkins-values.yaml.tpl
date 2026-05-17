controller:
  image:
    registry: ${REGISTRY_HOST}
    repository: ${REGISTRY_PATH}/jenkins
    tag: "${JENKINS_IMAGE_TAG}"
    pullPolicy: Always

  numExecutors: 0

  podSecurityContextOverride:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault

  containerSecurityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
    seccompProfile:
      type: RuntimeDefault
    readOnlyRootFilesystem: false

  sidecars:
    configAutoReload:
      containerSecurityContext:
        runAsUser: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault

  installPlugins: false
  installLatestPlugins: false

  resources:
    requests: { cpu: "500m", memory: "1Gi" }
    limits:   { cpu: "2",    memory: "3Gi" }

  javaOpts: "-Xms768m -Xmx2g -Duser.language=en -Duser.country=US"

  JCasC:
    defaultConfig: false
    configScripts:
      welcome: |
        jenkins:
          systemMessage: "SRE challenge Jenkins on GKE"
          numExecutors: 0
      kubernetes-cloud: |
        jenkins:
          clouds:
            - kubernetes:
                name: kubernetes
                serverUrl: https://kubernetes.default.svc
                namespace: jenkins-build
                jenkinsUrl: http://jenkins.jenkins.svc.cluster.local:8080
                jenkinsTunnel: jenkins-agent.jenkins.svc.cluster.local:50000
                skipTlsVerify: true
                containerCapStr: "10"
                connectTimeout: 60
                readTimeout: 60
      jenkins-url: |
        unclassified:
          location:
            url: "https://${JENKINS_HOST}/"
            adminAddress: "admin@${INGRESS_DOMAIN}"
      seed-pipeline: |
        jobs:
          - script: >
              pipelineJob('sre-challenge') {
                description('On-cluster build → push → deploy → smoke')
                definition {
                  cpsScm {
                    scm {
                      git {
                        remote { url('${GIT_REPO_URL}') }
                        branch('*/${GIT_BRANCH}')
                      }
                    }
                    scriptPath('Jenkinsfile')
                  }
                }
                triggers { scm('H/5 * * * *') }
              }
      script-security: |
        security:
          globalJobDslSecurityConfiguration:
            useScriptSecurity: false

  ingress:
    enabled: false

agent:
  enabled: true
  podName: jenkins-agent
  customJenkinsLabels:
    - k8s
  namespace: jenkins-build
  runAsUser: 1000
  runAsGroup: 1000
  containerCap: 10

persistence:
  enabled: true
  size: 8Gi

rbac:
  create: true

serviceAccount:
  create: true
  name: jenkins
