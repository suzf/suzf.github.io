---
title: "Dockerfile Pitfalls Guide"
slug: "dockerfile pitfalls guide"
date: 2026-03-31T22:23:03+08:00
author: "Jeffrey Su"
description: "12 Dockerfile traps that bite in production, each with the symptom you'll see, why it happens, the fix and how to check: stale apt caches, shell-form ENTRYPOINT, leaked secrets, Alpine's musl, missing CA certificates, VOLUME, time zones, cache misses and zombie processes."
categories: ["Skills Matrix"]
tags: ["docker", "devops"]
toc: true
draft: false
---

Most Dockerfile mistakes don't fail the build. The image builds, the container starts, and the problem shows up later: a deploy that takes ten seconds to stop, a TLS error only in production, logs eight hours off, a password readable by anyone who pulls the image. This post collects the twelve traps I've seen most often. For each one: the symptom you'll actually notice, why it happens, the fix, and how to check for it. A symptom-to-pitfall table at the end helps when you're debugging.

<!--more-->

To check your own Dockerfile against these pitfalls, paste it into the free [Dockerfile Linter](https://suzf.net/en/tools/dockerfile-linter) I built. It runs in your browser and links each finding back to the pitfall below that explains it.

## Pitfall 1: Separating apt-get update and install

```dockerfile
# ❌ The update layer is cached on its own
RUN apt-get update
RUN apt-get install -y curl

# ✅ Update, install and clean up in one layer
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
```

**Symptom:** weeks after the Dockerfile was written, someone adds a package to the install line and the build fails with `404 Not Found` or `Unable to locate package`, or it installs an old version with known vulnerabilities.

**Why:** Docker caches each `RUN` by its command text. `RUN apt-get update` never changes, so its layer, with the package index from the day it was first built, is reused forever. When the install line changes, only that step reruns, against a stale index that points at package versions the mirror has since deleted.

**Fix:** always chain `apt-get update` with the install in the same `RUN`, so any change to the package list refreshes the index too. Delete `/var/lib/apt/lists/*` in that same step: the index is ~20–40MB and is useless in the final image. The same applies to `apk update` (use `apk add --no-cache` instead) and `yum`/`dnf` (`dnf install -y … && dnf clean all`).

## Pitfall 2: COPY . . Before Dependency Install

```dockerfile
# ❌ Any file change invalidates the dependency install
COPY . .
RUN pip install -r requirements.txt

# ✅ Dependency manifest first, source code after
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
```

**Symptom:** a one-line code change makes the build download and install every dependency again, and a build that should take 30 seconds takes five minutes.

**Why:** the cache key of a `COPY` step is the checksum of every file it copies. `COPY . .` copies everything, so any edit, even to a README, misses the cache, and every step after it reruns, including the install.

**Fix:** copy only the files the install needs (`requirements.txt`, `package.json` + `package-lock.json`, `go.mod` + `go.sum`, `Gemfile` + `Gemfile.lock`), install, then copy the rest. The install layer is now reused until the dependency list itself changes. See [build cache](https://suzf.net/en/blog/posts/dockerfile-best-practices/#3-leverage-build-cache-effectively) for cache mounts, which speed up the install even when it does rerun.

## Pitfall 3: Shell Form ENTRYPOINT

```dockerfile
# ❌ Shell form: runs as /bin/sh -c "python app.py", so PID 1 is sh
ENTRYPOINT python app.py

# ✅ Exec form: python runs directly as PID 1
ENTRYPOINT ["python", "app.py"]
```

**Symptom:** `docker stop`, a rolling deploy or a Kubernetes pod deletion always takes exactly 10 seconds (or whatever the grace period is), and the app never logs its shutdown message. In-flight requests are cut off.

**Why:** in shell form, Docker starts `/bin/sh -c "…"` and your app runs as its child. Stopping the container sends SIGTERM to PID 1, the shell, which doesn't forward it. The app keeps running until the grace period ends and the kernel delivers SIGKILL, which can't be caught or handled.

**Fix:** use the exec form, a JSON array, for `ENTRYPOINT` and `CMD`. If you need a wrapper script, end it with `exec "$@"` (or `exec python app.py`) so the real process replaces the shell.

Two things the exec form doesn't do: it doesn't expand variables (`["echo", "$HOME"]` prints `$HOME` literally) and it doesn't parse shell syntax like `&&` or pipes. If you need those, put them in a script that ends with `exec`.

**Check:** `docker exec <container> ps -o pid,comm` (if the image has `ps`). PID 1 should be your app or an init like tini, not `sh`.

## Pitfall 4: Setting Environment Variables in RUN

```dockerfile
# ❌ Each RUN is a fresh shell: the export is gone at the next step
RUN export APP_HOME=/opt/app
RUN cd $APP_HOME   # $APP_HOME is empty, so this runs "cd" and lands in /root

# ✅ ENV persists for later steps and at runtime
ENV APP_HOME=/opt/app
WORKDIR $APP_HOME
```

**Symptom:** a later step runs in the wrong directory or with a missing setting, often without an error, because an empty variable just expands to nothing.

**Why:** every `RUN` starts a new shell process. Variables exported in one step, and `cd`, are lost when that shell exits.

**Fix:** pick the instruction that matches the lifetime you want:

| You want | Use |
|---|---|
| A variable in later build steps **and** at runtime | `ENV NAME=value` |
| A value only during the build (version numbers, flags) | `ARG NAME=value` |
| A variable for a single command | `RUN NAME=value command` |
| To change directory | `WORKDIR /path` (not `RUN cd`) |

Don't use `ARG` or `ENV` for secrets: both show up in `docker history` (see pitfall 6).

## Pitfall 5: Missing .dockerignore Causes Bloated Images

Without a `.dockerignore`, `docker build .` sends the whole directory to the builder, and `COPY . .` puts all of it into the image:

```text
.git/           # often bigger than the code itself
node_modules/   # built for your laptop's OS and CPU
.env            # real credentials
*.log
dist/
coverage/
```

**Symptom:** the build spends a long time on "transferring context", the image is far bigger than the app, or the app crashes in the container with an error about a native module (`invalid ELF header`, `Error: … was compiled against a different Node.js version`).

**Why:** a project with a few MB of source can easily have hundreds of MB of Git history. A local `node_modules` with native modules compiled on macOS gets copied over the one installed inside the image and doesn't run on Linux. And a `.env` file copied into a layer is readable by anyone who can pull the image.

**Fix:** add a `.dockerignore` next to the Dockerfile. A [complete example](https://suzf.net/en/blog/posts/dockerfile-best-practices/#6-use-dockerignore) is in the best-practices post.

**Check:** the first line of a BuildKit build shows the context size (`transferring context: 2.1MB`). If it's large, find out what's in it before anything else.

## Pitfall 6: Hardcoded Secrets in Images

```dockerfile
# ❌ Baked into the image: visible in docker history and in the layers
ENV DB_PASSWORD=my_secret_password
ARG NPM_TOKEN
RUN echo "password=my_secret_password" > /app/config
RUN rm /app/config   # too late: the file is still in the previous layer

# ✅ Runtime secrets come from the environment when the container starts
#    docker run -e DB_PASSWORD=... myapp   (or Kubernetes Secrets, Vault, etc.)
# ✅ Build-time secrets use a BuildKit secret mount
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
```

**Symptom:** usually none, until a secret scanner or an attacker finds it. Anyone who can pull the image can read it.

**Why:** an image is a stack of layers, and each layer is a tarball anyone with pull access can extract. Deleting a file in a later layer only hides it. `ENV` and `ARG` values are stored in the image config and printed by `docker history --no-trunc`.

**Fix:** pass runtime secrets when the container starts (environment variables, mounted files, a secrets manager). For secrets the build needs, such as a private registry token, use [BuildKit secret mounts](https://suzf.net/en/blog/posts/dockerfile-best-practices/#11-keep-secrets-out-of-layers), which never write the secret to a layer.

**If a secret has already shipped**, rebuilding without it isn't enough: every copy of the old image (registries, caches, laptops) still contains it. Treat it as leaked and rotate it; the [Password Generator](https://suzf.net/en/tools/password-generator) gives you a strong random replacement.

**Check:** `docker history --no-trunc <image>` shows every `ENV`, `ARG` and `RUN` command. Scanners like `trivy image --scanners secret` look inside the layers.

## Pitfall 7: Alpine DNS and glibc Issues

```dockerfile
# ❌ A binary built on a glibc system, copied to musl-based Alpine
FROM alpine:3.19
COPY myapp /usr/local/bin/
CMD ["myapp"]
# exec /usr/local/bin/myapp: no such file or directory
```

**Symptom:** the container exits immediately with `no such file or directory`, even though `ls` shows the file is right there.

**Why:** Alpine uses musl libc instead of glibc. A dynamically linked binary built on Debian, Ubuntu or the `golang` image asks the kernel for the glibc loader (`/lib64/ld-linux-x86-64.so.2`), which doesn't exist on Alpine. The "file not found" is the loader, not your binary. `file myapp` on the host shows `dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2`.

**Fix:**
- Go: build with `CGO_ENABLED=0` to get a static binary that runs anywhere, including `scratch`.
- Build inside an Alpine-based image (`golang:1.22-alpine`, `rust:alpine`) so the binary links against musl.
- Or don't use Alpine for this app: `debian:bookworm-slim` or distroless are glibc-based and only somewhat larger.

**DNS:** musl's resolver also behaves differently from glibc's. Before musl 1.2.4 (Alpine 3.18), it didn't retry over TCP when a DNS response was truncated, so names with large answers failed to resolve. It also queries all nameservers in parallel and handles `search` domains differently, which shows up in Kubernetes as slow or intermittent lookups. Use Alpine 3.18 or later; if you still see odd resolution errors, test the same app on a Debian-based image before you dig further.

Python and Node have the same musl issue: many prebuilt wheels and native npm modules exist only for glibc, so on Alpine they compile from source (slow, needs build tools) or fail. For those languages the slim Debian images are usually the better trade.

## Pitfall 8: Forgetting Runtime Dependencies in Multi-stage Builds

```dockerfile
FROM golang:1.22 AS builder
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /server .

FROM alpine:3.19
COPY --from=builder /server /usr/local/bin/server
# ❌ Works locally, then in production:
#    x509: certificate signed by unknown authority
#    unknown time zone Asia/Shanghai

# ✅ Install what the program needs at runtime
RUN apk add --no-cache ca-certificates tzdata
```

**Symptom:** the app starts fine, then fails on its first HTTPS call, its first time zone conversion, or its first call into a shared library.

**Why:** the runtime stage contains only what you put into it. The builder image had CA certificates, the time zone database and shared libraries; a minimal runtime image may have none of them, and nothing complains until the code path that needs them runs.

**Fix:** list what the binary needs and add it explicitly:

| Missing | Symptom | Add |
|---|---|---|
| CA certificates | `x509: certificate signed by unknown authority` | `ca-certificates`, or `COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/` for `scratch` |
| Time zone data | `unknown time zone`, or times silently in UTC | `tzdata`, or in Go `import _ "time/tzdata"` to embed it |
| Shared libraries | `error while loading shared libraries: libxyz.so` | the matching package, or link statically |
| User database | `user: unknown userid` | a `/etc/passwd` entry, or use a numeric `USER` |

**Check:** for a dynamically linked binary, `ldd /usr/local/bin/server` inside the runtime image lists any missing libraries. And run the image's real workload (an outbound HTTPS request included) in CI, not just "does it start".

## Pitfall 9: Implicit VOLUME Behavior

```dockerfile
# ⚠️ What happens to this write depends on the builder and on how the container runs
VOLUME /data
RUN echo "init" > /data/config
```

**Symptom:** files the Dockerfile puts in a directory are missing when the container runs, but only on some machines, or only in Kubernetes. Or `docker volume ls` shows hundreds of anonymous volumes nobody created on purpose.

**Why:** `VOLUME` does more than document a path:

- **Builds differ.** Files written to the path *after* the `VOLUME` line are discarded by the legacy builder but kept by BuildKit, so the same Dockerfile produces different images.
- **Mounts hide image content.** When a container starts, Docker copies the image's files at that path into a *new, empty* volume, so it looks like it works. But a bind mount, a named volume that already has data, or a Kubernetes volume is mounted *over* the path and hides what the image put there.
- **Every `docker run` creates a new anonymous volume** unless you mount one explicitly. They're not removed with the container unless you use `docker run --rm` or `docker rm -v`, and they pile up.
- **It can't be undone.** An image built `FROM` yours inherits the `VOLUME` and has no instruction to remove it.

**Fix:** write any files before the `VOLUME` line, or better, have the entrypoint script create default files on first start when the directory is empty, which works for every kind of mount. Many teams leave `VOLUME` out of the Dockerfile entirely and declare volumes where the container runs (Compose, Kubernetes), where the storage is actually decided.

## Pitfall 10: Timezone and Locale Issues

```dockerfile
# ❌ TZ alone does nothing if the zone database is missing
ENV TZ=Asia/Shanghai

# ✅ Alpine: install tzdata so TZ can be resolved
RUN apk add --no-cache tzdata
ENV TZ=Asia/Shanghai

# ✅ Debian/Ubuntu: C.UTF-8 is built in, no package needed
ENV LANG=C.UTF-8
```

**Symptom:** log timestamps and scheduled jobs are hours off; non-ASCII text (Chinese file names, accented names) turns into `?` or garbage; Python or Perl prints locale warnings.

**Why:** `TZ=Asia/Shanghai` is just a name looked up in `/usr/share/zoneinfo`. Alpine, distroless/static and some slim images don't include that database, and when the lookup fails glibc and musl silently fall back to UTC. For text, programs follow `LANG`/`LC_ALL`; with no UTF-8 locale set they fall back to ASCII (`POSIX`).

**Fix:**
- **Time zone:** make sure the zone database exists (`ls /usr/share/zoneinfo/Asia/Shanghai`): install `tzdata` on Alpine and on any image where it's missing, or embed it in the binary (Go: `import _ "time/tzdata"`). Then set `TZ`.
- **Locale:** on Debian, Ubuntu and other glibc images, `ENV LANG=C.UTF-8` is enough for UTF-8 text. You only need the `locales` package for a specific language locale, and on Debian `locale-gen` reads `/etc/locale.gen`, so uncomment the line rather than passing an argument:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends locales \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
```

A different approach many teams prefer: keep every container in UTC, store and log in UTC, and convert to local time only for display. Time zone bugs then come down to a single conversion point. The [Unix timestamps and time zones](https://suzf.net/en/blog/posts/unix-timestamps-and-time-zones/) post covers why.

## Pitfall 11: Hidden Causes of Cache Invalidation

A step you didn't touch rebuilds every time, or one you expected to rebuild doesn't. Common causes:

- **Files you didn't mean to copy.** `COPY . .` includes logs, editor swap files and build output unless `.dockerignore` excludes them, and any change to them invalidates that step and everything after it (pitfalls 2 and 5).
- **File permissions.** The `COPY` cache key includes file metadata such as mode bits, so a `chmod +x` on a copied file is a cache miss even though the content is the same. Modification times are *not* part of the key, so a fresh `git clone` doesn't bust the cache by itself.
- **Changing `ARG` values.** Passing a different `--build-arg` invalidates the cache from the first instruction that uses that argument. A build arg filled with the current date or commit hash, often added for a label, rebuilds every step after it on every build. Declare such args as late as possible.
- **Cache that is valid but stale.** The opposite problem: `RUN apt-get update` or `RUN git clone …` never change text, so they're cached forever (pitfall 1). Use `--no-cache` or `--no-cache-filter <stage>` when you deliberately want fresh results.
- **A fresh CI machine.** With no local cache, every step rebuilds. Export the cache to a registry (see [build cache in CI](https://suzf.net/en/blog/posts/dockerfile-best-practices/#3-leverage-build-cache-effectively)).

A related trap that looks like a cache problem, an `ARG` that seems to lose its value:

```dockerfile
# ❌ An ARG declared before FROM is out of scope inside the stage
ARG VERSION=3.19
FROM alpine:$VERSION
RUN echo $VERSION   # prints an empty line

# ✅ Re-declare it (without a value) inside the stage to bring it into scope
ARG VERSION=3.19
FROM alpine:$VERSION
ARG VERSION
RUN echo $VERSION   # 3.19
```

`ARG`s before the first `FROM` can be used in `FROM` lines only. Every stage starts with them out of scope, and an unset variable expands to an empty string without any error, so a download URL quietly becomes `app-.tgz`.

**Check:** `docker build --progress=plain .` prints `CACHED` next to every reused step. The first step without it is where the cache broke.

## Pitfall 12: Zombie Process Problem

```dockerfile
# ✅ tini as PID 1: forwards signals and reaps zombies
RUN apk add --no-cache tini
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["python", "app.py"]
```

**Symptom:** `ps` in the container shows a growing list of `<defunct>` processes; eventually the container can't start new processes (`fork: Resource temporarily unavailable`). Or SIGTERM does nothing even though you used the exec form.

**Why:** PID 1 has two special duties in Linux. It adopts orphaned processes and must reap them when they exit, and it gets no default signal handlers, so SIGTERM is ignored unless the program installs a handler. Most applications aren't written to be PID 1. If your app (or a shell script) spawns child processes, for example a Node app calling a CLI tool, or Chrome for screenshots, the finished children are never reaped and stay as zombies.

**Fix:** run a minimal init as PID 1 that does both jobs and starts your app as its child:

- `docker run --init` adds Docker's bundled init (tini) without changing the image.
- Install tini in the image (`apk add tini` puts it at `/sbin/tini`; on Debian `apt-get install tini` puts it at `/usr/bin/tini`) and use it as the `ENTRYPOINT`, which works everywhere the image runs.
- In Kubernetes there's no `--init` flag: put tini in the image, or set `shareProcessNamespace: true` on the pod so the pause container becomes PID 1 and reaps zombies.

You don't need an init if your app is a single process that never spawns children and handles SIGTERM itself, which is true of many Go services.

## Quick Reference: Symptom to Pitfall

| You see | Look at |
|---|---|
| `apt-get install` fails with 404 / "Unable to locate package" | Pitfall 1 |
| Every code change reinstalls all dependencies | Pitfalls 2, 11 |
| `docker stop` always takes 10 seconds | Pitfalls 3, 12 |
| A variable set in one `RUN` is empty in the next | Pitfall 4 |
| "Transferring context" is slow, image is huge, native module errors | Pitfall 5 |
| A password shows up in `docker history` | Pitfall 6 |
| `exec …: no such file or directory` for a file that exists | Pitfall 7 |
| `x509: certificate signed by unknown authority` | Pitfall 8 |
| Files in a directory disappear at runtime | Pitfall 9 |
| Times are hours off, non-ASCII text is garbled | Pitfall 10 |
| An `ARG` is empty inside the stage | Pitfall 11 |
| `<defunct>` processes pile up | Pitfall 12 |

For the habits that keep most of these from happening in the first place, see [Dockerfile Best Practices](https://suzf.net/en/blog/posts/dockerfile-best-practices/).
