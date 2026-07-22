# Stage 1: Build stage
FROM eclipse-temurin:21-jdk-jammy AS builder
WORKDIR /workspace
COPY . .
RUN curl -fLo scala-cli https://github.com/Virtuslab/scala-cli/releases/latest/download/scala-cli-x86_64-pc-linux.gz && \
    gunzip scala-cli && chmod +x scala-cli && ./scala-cli package . -o app.jar --assembly

# Stage 2: Runtime stage
FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=builder /workspace/app.jar /app/app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
