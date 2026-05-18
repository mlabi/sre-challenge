pipeline {
    agent {
        kubernetes {
            label 'kaniko'
            defaultContainer 'tools'
            yaml '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins/label: kaniko
spec:
  serviceAccountName: jenkins
  # kaniko needs root to unpack base layers, so no pod-level runAsNonRoot.
  # Other containers pin to UID 1000 individually.
  containers:
    - name: jnlp
      image: jenkins/inbound-agent:latest-jdk21
      securityContext:
        runAsUser: 1000
      resources:
        requests:
          cpu: "100m"
          memory: "256Mi"
        limits:
          cpu: "500m"
          memory: "512Mi"
    - name: gradle
      image: gradle:8.10-jdk21
      command: ["sleep"]
      args: ["infinity"]
      securityContext:
        runAsUser: 1000
      envFrom:
        - configMapRef:
            name: sre-challenge-vars
      resources:
        requests:
          cpu: "500m"
          memory: "1Gi"
        limits:
          cpu: "2"
          memory: "3Gi"
    - name: kaniko
      image: gcr.io/kaniko-project/executor:v1.23.2-debug
      command: ["sleep"]
      args: ["infinity"]
      envFrom:
        - configMapRef:
            name: sre-challenge-vars
      volumeMounts:
        - name: dockerconfig
          mountPath: /kaniko/.docker
        - name: lab-ca
          mountPath: /kaniko/ssl/certs/sre-lab-ca.crt
          subPath: ca.crt
    - name: tools
      image: alpine/k8s:1.31.1
      command: ["sleep"]
      args: ["infinity"]
      securityContext:
        runAsUser: 1000
      envFrom:
        - configMapRef:
            name: sre-challenge-vars
      volumeMounts:
        - name: lab-ca
          mountPath: /tmp/lab-ca.crt
          subPath: ca.crt
  volumes:
    - name: dockerconfig
      secret:
        secretName: registry-pull
        items:
          - key: .dockerconfigjson
            path: config.json
    - name: lab-ca
      secret:
        secretName: lab-ca
        items:
          - key: ca.crt
            path: ca.crt
'''
        }
    }

    options {
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    environment {
        APP_VERSION = "${env.BUILD_NUMBER ? '0.1.' + env.BUILD_NUMBER : '0.1.0'}"
    }

    stages {
        stage('Gradle build') {
            steps {
                container('gradle') {
                    sh '''
                        ./gradlew --no-daemon clean build -x test
                        ls -la app/*/build/libs/
                    '''
                }
            }
        }

        stage('Build & push images') {
            steps {
                container('kaniko') {
                    script {
                        ['front', 'back', 'reader'].each { app ->
                            sh """
                                /kaniko/executor \\
                                    --context=\$PWD \\
                                    --dockerfile=docker/Dockerfile \\
                                    --destination=\$REGISTRY_INTERNAL_HOST/${app}:${APP_VERSION} \\
                                    --destination=\$REGISTRY_INTERNAL_HOST/${app}:latest \\
                                    --build-arg JAR_FILE=app/${app}/build/libs/${app}-0.1.0.jar \\
                                    --cache=true \\
                                    --cache-repo=\$REGISTRY_INTERNAL_HOST/kaniko-cache
                            """
                        }
                    }
                }
            }
        }

        stage('Helm deploy') {
            steps {
                container('tools') {
                    sh """
                        for app in front back reader; do
                            helm upgrade --install \$app charts/app \\
                                --namespace demo-\$app \\
                                -f charts/app/values-\$app.yaml \\
                                --set image.repository=\$REGISTRY_INTERNAL_HOST/\$app \\
                                --set image.tag=${APP_VERSION} \\
                                --set ingress.baseDomain=\$INGRESS_BASE_DOMAIN \\
                                --wait --timeout=3m
                        done
                    """
                }
            }
        }

        stage('Smoke test') {
            steps {
                container('tools') {
                    sh '''
                        FRONT_URL=http://front.demo-front.svc.cluster.local:8080 \\
                        READER_URL=http://reader.demo-reader.svc.cluster.local:8080 \\
                        SKIP_CA_CHECK=1 \\
                            bash docker/smoke-test.sh
                    '''
                }
            }
        }
    }

}
