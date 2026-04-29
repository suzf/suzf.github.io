---
title: "Dockerfile Pitfalls Guide"
slug: "dockerfile pitfalls guide"
date: 2026-03-31T22:23:03+08:00
author: "Jeffrey Su"
description: ""
categories: ["Skills Matrix"]
tags: ["docker", "devops"]
toc: true
lightgallery: true
draft: false
---

Writing a Dockerfile seems simple, but production environments are full of hidden traps. This post covers common Dockerfile pitfalls and their solutions to help you avoid painful debugging sessions.

<!--more-->

### Pitfall 1: Separating apt-get update and install

```dockerfile
# ❌ Cache layer issue: cached update may cause install to fail or use stale packages
RUN apt-get update
RUN apt-get install -y curl

# ✅ Combine into one layer
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
```

When `apt-get update` is in its own layer, it gets cached. Later changes to the install list won't re-run update, causing package resolution failures.

---

### Pitfall 2: COPY . . Before Dependency Install

```dockerfile
# ❌ Any file change invalidates the dependency install cache
COPY . .
RUN pip install -r requirements.txt

# ✅ Copy dependency files first, then source code
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
```

A single line of code change triggers a full dependency reinstall — build time goes from 30 seconds to 5 minutes.

---

### Pitfall 3: Shell Form ENTRYPOINT

```dockerfile
# ❌ Shell form: process starts via /bin/sh -c, PID 1 is sh, not your app
ENTRYPOINT python app.py

# ✅ Exec form: app runs directly as PID 1
ENTRYPOINT ["python", "app.py"]
```

Consequences of shell form:
- SIGTERM from `docker stop` is swallowed by sh — your app never receives it
- Container waits 10 seconds then gets SIGKILL
- Graceful shutdown completely broken

---

### Pitfall 4: Setting Environment Variables in RUN

```dockerfile
# ❌ Each RUN is an independent shell, variables don't persist
RUN export APP_HOME=/opt/app
RUN cd $APP_HOME  # $APP_HOME is empty

# ✅ Use ENV instruction
ENV APP_HOME=/opt/app
RUN cd $APP_HOME && do_something
```

---

### Pitfall 5: Missing .dockerignore Causes Bloated Images

Without `.dockerignore`, `COPY . .` sends everything to the Docker daemon:

```
# Commonly leaked files
.git/          # Can be hundreds of MB
node_modules/  # Local deps may have wrong architecture
.env           # Contains secrets — serious security risk
*.log
dist/
```

**Real case:** A Node.js project with 5MB source code but 800MB `.git` directory — build context transfer alone takes 30 seconds.

---

### Pitfall 6: Hardcoded Secrets in Images

```dockerfile
# ❌ Secrets persist in image layers, visible via docker history even after deletion
ENV DB_PASSWORD=my_secret_password
RUN echo "password=my_secret_password" > /app/config

# ✅ Inject at runtime
# docker run -e DB_PASSWORD=xxx myapp
# Or use Docker secrets / Vault
```

Even if you `RUN rm /app/config` in a later layer, the intermediate layer still contains the file.

---

### Pitfall 7: Alpine DNS and glibc Issues

```dockerfile
# ❌ Some apps depend on glibc, but alpine uses musl libc
FROM alpine:3.19
COPY myapp /usr/local/bin/
# Runtime error: /lib/x86_64-linux-gnu/libc.so.6: No such file or directory
```

Solutions:
- Static linking at compile time: `CGO_ENABLED=0` (Go)
- Switch to `debian:bookworm-slim` or `distroless`
- Alpine's DNS resolution can be problematic under high concurrency (musl's DNS implementation differs from glibc)

---

### Pitfall 8: Forgetting Runtime Dependencies in Multi-stage Builds

```dockerfile
FROM golang:1.22 AS builder
RUN go build -o server .

FROM alpine:3.19
COPY --from=builder /go/src/app/server /usr/local/bin/
# ❌ If the app needs ca-certificates or timezone data, it will fail at runtime
# TLS error: x509: certificate signed by unknown authority

# ✅ Install runtime dependencies
RUN apk add --no-cache ca-certificates tzdata
```

Commonly missed:
- `ca-certificates` — required for HTTPS requests
- `tzdata` — required for timezone functions
- Shared libraries — if not statically compiled

---

### Pitfall 9: Implicit VOLUME Behavior

```dockerfile
# ⚠️ Modifications to the directory after VOLUME are discarded
VOLUME /data
RUN echo "init" > /data/config  # This write is overridden by an anonymous volume at runtime
```

After a `VOLUME` declaration, subsequent RUN writes to that path are overridden by an empty anonymous volume at container start. Initialize data before `VOLUME`, or use an entrypoint script for runtime initialization.

---

### Pitfall 10: Timezone and Locale Issues

```dockerfile
# ❌ Default UTC timezone — log timestamps don't match host
# ❌ Missing locale causes garbled non-ASCII characters

# ✅ Set timezone
ENV TZ=Asia/Shanghai
RUN apk add --no-cache tzdata

# ✅ Set locale on Debian-based images
RUN apt-get update && apt-get install -y locales \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
```

---

### Pitfall 11: Hidden Causes of Cache Invalidation

Common reasons cache breaks unexpectedly:

- **File permission changes:** `chmod` doesn't change content, but invalidates cache
- **Timestamp changes:** `git clone` produces different mtimes, breaking cache
- **BuildKit vs legacy engine:** `DOCKER_BUILDKIT=1` has different caching behavior
- **ARG before FROM:** ARG declared before FROM doesn't carry into the build stage

```dockerfile
# ❌ ARG declared before FROM is not available after FROM
ARG VERSION=3.19
FROM alpine:$VERSION
RUN echo $VERSION  # empty

# ✅ Re-declare ARG after FROM
ARG VERSION=3.19
FROM alpine:$VERSION
ARG VERSION
RUN echo $VERSION  # 3.19
```

---

### Pitfall 12: Zombie Process Problem

PID 1 inside a container doesn't automatically reap child processes, leading to zombie process accumulation:

```dockerfile
# ✅ Use tini as init process
RUN apk add --no-cache tini
ENTRYPOINT ["tini", "--"]
CMD ["python", "app.py"]
```

Alternatively, add `--init` flag to `docker run`.

---
