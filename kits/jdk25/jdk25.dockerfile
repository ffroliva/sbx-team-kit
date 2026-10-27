# syntax=docker/dockerfile:1
# Multi-stage: take the JDK from the official image, ship only that directory.
FROM eclipse-temurin:25-jdk AS jdk
FROM scratch
COPY --from=jdk /opt/java/openjdk /opt/java/openjdk
