---
title: "Dockerfile Best Practices"
slug: "dockerfile best practices"
date: 2026-03-31T22:20:51+08:00
author: "Jeffrey Su"
description: "Dockerfile practices that pay off in daily work, each with the reason behind it: multi-stage builds, base images, build cache and cache mounts, small layers, non-root users, .dockerignore, COPY vs ADD, ENTRYPOINT vs CMD, health checks, scanning, build secrets and pinned versions, plus a complete example."
categories: ["Skills Matrix"]
tags: ["docker", "devops"]
toc: true
draft: false
---

A good Dockerfile builds fast, produces a small image, and gives an attacker as little as possible to work with. Most of the difference between a good Dockerfile and a bad one comes from a dozen habits. This post goes through them one by one, with the reason behind each, because "always do X" is easy to forget while "X because Y" sticks. A complete Dockerfile that uses all of them is at the end.

<!--more-->

To check your own Dockerfile against these practices, paste it into the free [Dockerfile Linter](https://suzf.net/en/tools/dockerfile-linter) I built. It runs in your browser and links each finding back to the section here that explains it.

## 1. Use Multi-stage Builds

Compilers, build tools and dev dependencies are needed to build your app, not to run it. A multi-stage build uses one stage to build and a second, minimal stage to run, copying across only the result:

```dockerfile
# Build stage: full toolchain
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o server .

# Runtime stage: just the binary and CA certificates
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/server /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["server"]
```

The build stage weighs a few hundred MB; the final image is around 15–20MB. Nothing from the build stage reaches the final image unless you `COPY --from` it, so the Go toolchain, the module cache and your source code all stay behind.

A few things that make stages more useful:

- `docker build --target builder .` builds only up to a named stage, which is handy for a test stage that runs in CI but never ships.
- BuildKit (the default builder since Docker 23) skips stages the target doesn't depend on, and builds independent stages in parallel.
- Interpreted languages benefit too: install dependencies with build tools (`gcc` for native Python wheels, `node-gyp` for npm modules) in one stage, then copy only the installed packages into a slim runtime stage.

## 2. Choose the Right Base Image

The base image sets the floor for your image's size and its number of known vulnerabilities, so pick the smallest one your app can actually run on:

| Use case | Base image | Approx. size |
|---|---|---|
| Static binaries (Go, Rust) | `scratch` / `gcr.io/distroless/static-debian12` | 0–2MB |
| General purpose, small | `alpine:3.19` | ~7MB |
| Needs glibc / Debian packages | `debian:bookworm-slim` | ~75MB |
| Python | `python:3.12-slim` | ~130MB |
| Node.js | `node:20-bookworm-slim` | ~200MB |

Sizes are uncompressed and vary by version and architecture.

Three things to watch:

- **Alpine uses musl, not glibc.** Most software doesn't care, but prebuilt binaries, some Python wheels and DNS behaviour can differ. See [the Alpine pitfall](https://suzf.net/en/blog/posts/dockerfile-pitfalls-guide/#pitfall-7-alpine-dns-and-glibc-issues) before you switch a Python or Node app to Alpine to save a few MB.
- **Distroless images have no shell and no package manager.** That is the point, as there is nothing for an attacker to use, but it also means no `RUN` in that stage and no `docker exec … sh` for debugging. Use the `:debug` variant while you're getting things working.
- **Never use `latest` or no tag at all.** `FROM node` gives you whatever was published this morning, and two builds of the same commit can produce different images. Pin at least the major and minor version (`node:20.18-bookworm-slim`); section 12 goes further.

## 3. Leverage Build Cache Effectively

Docker caches each instruction's result and reuses it as long as the instruction and its inputs haven't changed. For `COPY`, the input is the checksum of the copied files. Once one step misses the cache, every step after it runs again. So order instructions from least to most frequently changing:

```dockerfile
FROM node:20-bookworm-slim
WORKDIR /app

# Dependency manifests change rarely: this layer and the install stay cached
COPY package.json package-lock.json ./
RUN npm ci

# Source code changes on every commit: only the steps from here on rerun
COPY . .
RUN npm run build
```

If you `COPY . .` before `npm ci`, any change to any file, even a README, invalidates the dependency install, and every build downloads all of `node_modules` again.

**Cache mounts** go one step further. With BuildKit, a `RUN` step can mount a cache directory that persists between builds without becoming part of the image:

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=cache,target=/root/.npm npm ci
```

When the lock file changes and `npm ci` has to rerun, it still finds most packages in the mounted cache instead of downloading them. The same works for `pip` (`/root/.cache/pip`), Go (`/root/.cache/go-build` and `/go/pkg/mod`), `apt` and others.

**In CI**, every job often starts on a fresh machine with an empty cache. Export the cache to your registry and import it on the next run:

```bash
docker buildx build \
  --cache-from type=registry,ref=registry.example.com/app:buildcache \
  --cache-to   type=registry,ref=registry.example.com/app:buildcache,mode=max \
  -t registry.example.com/app:1.4.2 --push .
```

## 4. Minimize Layers and Image Size

Each `RUN`, `COPY` and `ADD` creates a layer, and layers only ever add to the image: deleting a file in a later layer hides it, but its bytes still ship in the earlier one. So whatever you download and then clean up must be cleaned up **in the same `RUN`**:

```dockerfile
# ❌ The package lists are deleted in a later layer, so they still ship
RUN apt-get update
RUN apt-get install -y curl
RUN rm -rf /var/lib/apt/lists/*

# ✅ One layer: update, install and clean up together
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*
```

`--no-install-recommends` stops apt from pulling in "recommended" packages, which often doubles what gets installed. Every package manager has an equivalent way to leave its cache behind:

| Package manager | Install without leaving a cache |
|---|---|
| apt | `apt-get install -y --no-install-recommends …` then `rm -rf /var/lib/apt/lists/*` |
| apk | `apk add --no-cache …` |
| dnf / yum | `dnf install -y … && dnf clean all` |
| pip | `pip install --no-cache-dir …` |
| npm | `npm ci --omit=dev` then `npm cache clean --force` |

To see where the size actually comes from, `docker history <image>` lists each layer with its size, and [dive](https://github.com/wagoodman/dive) lets you browse each layer's files.

Combining every command into one giant `RUN` isn't the goal, though: it kills caching. Group commands by what changes together (system packages in one step, app dependencies in another) and keep cleanup with the step that created the mess.

## 5. Don't Run as Root

Unless you say otherwise, the process in the container runs as root. Containers are isolated, but a root process that escapes through a kernel or runtime bug is root on the host, and even without an escape it can rewrite anything in its own filesystem. Create an unprivileged user and switch to it:

```dockerfile
# Debian / Ubuntu based images
RUN groupadd --system --gid 10001 app && \
    useradd --system --uid 10001 --gid app --no-create-home app

# Alpine based images
RUN addgroup -S -g 10001 app && adduser -S -u 10001 -G app app

COPY --chown=app:app . /app
USER 10001
```

Details that matter:

- **Use a numeric UID in `USER`.** Kubernetes' `runAsNonRoot` can only verify a numeric user; with `USER app` it can't tell whether `app` is root and refuses to start the pod.
- **Ports below 1024 need root** to bind. Listen on 8080 inside the container and map it to 80 outside.
- **Files the app writes need the right owner**: use `COPY --chown`, or `chown` the data directory in the same layer that creates it.
- Many official images already ship a user: `node` images have `node` (UID 1000), and distroless images have a `:nonroot` tag (UID 65532).

## 6. Use .dockerignore

`docker build .` sends the whole directory, the build context, to the builder before it runs a single instruction. Without a `.dockerignore`, that includes `.git`, `node_modules`, local build output and your `.env` file. It makes every build slower, it busts the cache whenever any of those files change (`COPY . .` copies them), and it can bake secrets into the image.

```text
# .dockerignore
.git
node_modules
dist
coverage
*.log
.env
.env.*
.DS_Store
Dockerfile
docker-compose*.yml

# exceptions start with !
!.env.example
```

The patterns follow Go's `filepath.Match` rules, with `**` matching any number of directories. If a build is slow to start ("transferring context: 900MB"), the `.dockerignore` is the first thing to check.

## 7. COPY vs ADD

```dockerfile
# ✅ COPY copies files, nothing else
COPY app.tar.gz /app/

# ⚠️ ADD also unpacks local tar archives and can download URLs
ADD app.tar.gz /app/
```

`ADD` has extra behaviour that isn't obvious from reading the line: a local `.tar`, `.tar.gz` and similar archives are unpacked into the destination, while a remote URL is downloaded but **not** unpacked. Someone reading `ADD config.tar.gz /etc/app/` has to know that rule to understand what lands on disk.

Use `COPY` by default. Use `ADD` only when you want a local archive unpacked. To download something, prefer a `RUN` with `curl` and a checksum check, or `ADD --checksum=sha256:…` with a recent Dockerfile frontend, so the build fails if the file changes under you.

## 8. ENTRYPOINT vs CMD

`ENTRYPOINT` sets the program the container runs; `CMD` sets its default arguments, which `docker run` can override:

```dockerfile
ENTRYPOINT ["python", "app.py"]
CMD ["--port", "8080"]
```

```bash
docker run myapp                 # python app.py --port 8080
docker run myapp --port 9090     # python app.py --port 9090
```

With only `CMD`, everything after the image name in `docker run` replaces the whole command, which suits images that are more of a toolbox than a single program.

**Always use the exec form** (`["executable", "arg"]`). The shell form (`ENTRYPOINT python app.py`) runs your program as a child of `/bin/sh -c`. The shell becomes PID 1 and doesn't forward signals, so `docker stop` sends SIGTERM to the shell, your app never sees it, and after 10 seconds Docker kills it with SIGKILL: no graceful shutdown, no flushed buffers, no closed connections.

If you need a startup script, end it with `exec "$@"` so the real process replaces the shell and receives signals directly:

```sh
#!/bin/sh
set -e
# ... prepare config, wait for dependencies ...
exec "$@"
```

If your app spawns child processes, it also has to reap them; use `docker run --init` or [tini](https://github.com/krallin/tini) as PID 1 (see [the zombie process pitfall](https://suzf.net/en/blog/posts/dockerfile-pitfalls-guide/#pitfall-12-zombie-process-problem)).

## 9. Health Checks

A running process isn't necessarily a working one. `HEALTHCHECK` tells Docker how to test the app from inside the container:

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1
```

Docker runs the command on that schedule and marks the container `healthy` or `unhealthy`, visible in `docker ps`. What happens next depends on who is watching:

- **Docker Compose** can make other services wait for it with `depends_on: { app: { condition: service_healthy } }`.
- **Docker Swarm** replaces unhealthy tasks.
- **Plain `docker run`** only reports the status; it does **not** restart an unhealthy container on its own.
- **Kubernetes ignores `HEALTHCHECK` entirely.** It uses the liveness, readiness and startup probes in the pod spec, so define those as well.

The check command has to exist in the image: slim images often lack `curl`, and distroless images have no shell at all. Use whatever is there (`wget` on Alpine), add a tiny health-check binary to the image, or skip `HEALTHCHECK` and rely on the orchestrator's probes.

## 10. Security Scanning

Your image inherits every known vulnerability in its base image and packages. Scan it after every build, and again regularly, because new vulnerabilities are published against images that haven't changed:

```bash
# Trivy: fail the job on high or critical findings
trivy image --exit-code 1 --severity HIGH,CRITICAL myapp:1.4.2

# Docker Scout
docker scout cves myapp:1.4.2
```

Lint the Dockerfile itself too. [hadolint](https://github.com/hadolint/hadolint) runs in CI, and the [Dockerfile Linter](https://suzf.net/en/tools/dockerfile-linter) gives the same kind of feedback in the browser. Most findings are fixed by the earlier sections: a smaller base image (section 2) and fewer installed packages (section 4) mean fewer vulnerabilities to begin with.

## 11. Keep Secrets Out of Layers

Anything that touches the image filesystem during the build ends up in a layer, even if a later step deletes it, and `ARG` and `ENV` values show up in `docker history`. So a private registry token passed as `--build-arg NPM_TOKEN=…` or copied in as `.npmrc` can be read by anyone who can pull the image.

BuildKit secret mounts make a file available to a single `RUN` step without writing it to any layer:

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
```

```bash
docker build --secret id=npmrc,src=$HOME/.npmrc -t myapp .
```

For cloning private Git repositories during a build, `RUN --mount=type=ssh` forwards your SSH agent the same way. Runtime secrets (database passwords, API keys) don't belong in the image at all: pass them as environment variables or mounted files when the container starts. See [the hardcoded secrets pitfall](https://suzf.net/en/blog/posts/dockerfile-pitfalls-guide/#pitfall-6-hardcoded-secrets-in-images) for how they leak.

## 12. Pin Versions for Reproducible Builds

Building the same commit twice should give you the same image. Every floating version breaks that: the base image tag moves, `apt-get install curl` picks up whatever is current, `npm install` ignores the lock file.

- **Base image**: a tag like `node:20.18-bookworm-slim` is still updated in place for patches. For exact reproducibility, pin the digest as well: `FROM node:20.18-bookworm-slim@sha256:…`. Tools like Renovate or Dependabot open a pull request when a new digest is published, so you still get security fixes, just reviewed.
- **App dependencies**: commit the lock file and use the install command that honours it exactly: `npm ci`, `pip install -r requirements.txt` with pinned versions (or a lock file from your tool), `go mod download` with `go.sum`.
- **System packages**: pinning every apt package version is usually more trouble than it's worth, since old versions disappear from the mirrors. Pinning the base image digest gives you most of the reproducibility.

## 13. Putting It Together

A Node.js service using everything above:

```dockerfile
# syntax=docker/dockerfile:1

# Production dependencies only
FROM node:20.18-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev

# Build with dev dependencies
FROM node:20.18-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npm run build

# Runtime: no shell, no package manager, non-root (UID 65532)
FROM gcr.io/distroless/nodejs20-debian12:nonroot
WORKDIR /app
COPY --from=deps  /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
EXPOSE 8080
CMD ["dist/server.js"]
```

What each part does:

- **Three stages** (section 1): dev dependencies and build tools never reach the runtime image.
- **Manifests before source** (section 3): editing code reruns only `COPY . .` and the build, and the npm cache mount speeds up a lock-file change.
- **Distroless `:nonroot` runtime** (sections 2 and 5): no shell or package manager to exploit, and the process runs as UID 65532. The distroless Node image's entrypoint is already `node`, so `CMD` only names the script, in exec form (section 8).
- **No `HEALTHCHECK`**: there is no shell or `wget` in a distroless image, so the health check lives in the orchestrator's probes instead (section 9).
- **Pinned versions** (section 12): add `@sha256:…` digests in production.

Together with a `.dockerignore` (section 6), a secret mount if `npm ci` needs a private registry (section 11), and a scan in CI (section 10), that covers everything in this post.
