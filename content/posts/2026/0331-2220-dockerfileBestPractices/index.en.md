---
title: "Dockerfile Best Practices"
slug: "dockerfile best practices"
date: 2026-03-31T22:20:51+08:00
author: "Jeffrey Su"
description: ""
categories: ["Skills Matrix"]
tags: ["docker", "devops"]
toc: true
lightgallery: true
draft: false
---

A well-written Dockerfile can significantly reduce image size, speed up builds, and improve security. This post summarizes the most practical Dockerfile conventions for daily work.

<!--more-->

### 1. Use Multi-stage Builds

Separate the build environment from the runtime environment — the final image only contains the artifacts needed to run:

```dockerfile
# Build stage
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o server .

# Runtime stage
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/server /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["server"]
```

Result: Go build image ~1GB → final image ~20MB.

---

### 2. Choose the Right Base Image

| Use Case | Recommended Image | Size |
|----------|------------------|------|
| General purpose | `alpine:3.19` | ~7MB |
| Static binaries | `scratch` / `gcr.io/distroless/static` | 0~2MB |
| Debian required | `debian:bookworm-slim` | ~80MB |
| Python | `python:3.12-slim` | ~150MB |

> Avoid the `latest` tag — always pin a specific version to ensure reproducible builds.

---

### 3. Leverage Build Cache Effectively

Docker caches by layer. **Place less frequently changing instructions first:**

```dockerfile
FROM node:20-alpine
WORKDIR /app

# Copy dependency files first (change infrequently)
COPY package.json package-lock.json ./
RUN npm ci --production

# Then copy source code (changes often)
COPY . .
RUN npm run build
```

If you `COPY . .` before `npm install`, every code change triggers a full dependency reinstall.

---

### 4. Minimize Layers and Image Size

```dockerfile
# ❌ Multiple RUN instructions create multiple layers
RUN apt-get update
RUN apt-get install -y curl
RUN rm -rf /var/lib/apt/lists/*

# ✅ Combine into one layer and clean up cache
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*
```

Key points:
- `--no-install-recommends` avoids pulling unnecessary packages
- Clean up cache in the same layer — otherwise the delete operation won't reduce image size

---

### 5. Don't Run as Root

```dockerfile
RUN addgroup -S app && adduser -S app -G app
USER app
```

Running containers as a non-root user reduces the attack surface in case of container escape.

---

### 6. Use .dockerignore

Create a `.dockerignore` in the project root to exclude irrelevant files from the build context:

```
.git
node_modules
*.md
.env
.DS_Store
dist
coverage
```

A smaller build context means faster `docker build` startup.

---

### 7. COPY vs ADD

```dockerfile
# ✅ Prefer COPY (explicit behavior)
COPY app.tar.gz /app/

# ⚠️ ADD auto-extracts tar and supports URLs (implicit behavior)
ADD app.tar.gz /app/
```

Only use `ADD` when you need automatic tar extraction. Use `COPY` for everything else.

---

### 8. ENTRYPOINT vs CMD

```dockerfile
# ENTRYPOINT defines the container's main process
# CMD provides default arguments, overridable via docker run
ENTRYPOINT ["python", "app.py"]
CMD ["--port", "8080"]
```

```bash
# Using default arguments
docker run myapp
# Equivalent to: python app.py --port 8080

# Overriding arguments
docker run myapp --port 9090
# Equivalent to: python app.py --port 9090
```

> Always use exec form `["executable", "param"]` — shell form prevents proper signal propagation.

---

### 9. Health Checks

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1
```

Works with orchestration tools (Docker Compose / Kubernetes) to automatically restart unhealthy containers.

---

### 10. Security Scanning

Scan images for vulnerabilities after building:

```bash
# Trivy
trivy image myapp:latest

# Docker Scout
docker scout cves myapp:latest
```

Integrate into your CI/CD pipeline to block images with critical vulnerabilities from being published.

---
