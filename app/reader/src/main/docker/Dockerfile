FROM ibm-semeru-runtimes:open-21-jre

ARG JAR_VERSION=0.1.0
ARG JAR_FILE=./reader-${JAR_VERSION}.jar

COPY --chown=1000:1000 ${JAR_FILE} /app.jar
USER 1000

ENTRYPOINT ["java", "-Djava.security.egd=file:/dev/./urandom", "-jar", "/app.jar"]
