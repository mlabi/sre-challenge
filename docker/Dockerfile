FROM gcr.io/distroless/java21-debian12:nonroot

WORKDIR /app

ARG JAR_FILE
COPY --chown=nonroot:nonroot ${JAR_FILE} /app/app.jar

USER nonroot

EXPOSE 8080 8081

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
