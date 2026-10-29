---
title: "Dockerfile 最佳实践"
slug: "dockerfile best practices"
date: 2026-03-31T22:20:51+08:00
author: "Jeffrey Su"
description: "日常工作中真正有用的 Dockerfile 写法，每条都讲清原因：多阶段构建、基础镜像、构建缓存与缓存挂载、减小镜像层、非 root 运行、.dockerignore、COPY 与 ADD、ENTRYPOINT 与 CMD、健康检查、安全扫描、构建期密钥和版本固定，最后附一个完整示例。"
categories: ["技能矩阵"]
tags: ["docker", "devops"]
toc: true
draft: false
---

好的 Dockerfile 构建快、镜像小，留给攻击者的东西尽可能少。好坏之间的差距，大多来自十几个习惯。本文逐条讲解，并且都讲清楚原因：光记“永远要做 X”很容易忘，知道“做 X 是因为 Y”才记得住。文末有一个把所有做法都用上的完整 Dockerfile。

<!--more-->

想检查自己的 Dockerfile 是否符合这些规范，可以把它粘贴到我做的免费 [Dockerfile 检查器](https://suzf.net/zh/tools/dockerfile-linter)。它在浏览器里运行，每条结果都会链接回本文讲解对应做法的那一节。

## 1. 使用多阶段构建 (Multi-stage Build)

编译器、构建工具和开发依赖只在构建时需要，运行时并不需要。多阶段构建用一个阶段编译，再用一个精简的阶段运行，只把编译结果复制过去：

```dockerfile
# 编译阶段：完整工具链
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o server .

# 运行阶段：只有二进制文件和 CA 证书
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/server /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["server"]
```

编译阶段有几百 MB，最终镜像只有 15–20MB 左右。除非用 `COPY --from` 显式复制，编译阶段的任何东西都不会进入最终镜像，Go 工具链、模块缓存和源代码都留在了后面。

几个让多阶段更好用的技巧：

- `docker build --target builder .` 只构建到指定阶段，适合放一个只在 CI 里运行、从不发布的测试阶段。
- BuildKit（Docker 23 起的默认构建器）会跳过目标阶段不依赖的阶段，并且并行构建互不依赖的阶段。
- 解释型语言同样受益：在一个阶段里带着构建工具安装依赖（Python 原生扩展要 `gcc`，npm 原生模块要 `node-gyp`），再只把装好的包复制到精简的运行阶段。

## 2. 选择合适的基础镜像

基础镜像决定了镜像体积和已知漏洞数量的下限，所以要选应用能跑起来的最小镜像：

| 场景 | 基础镜像 | 大致体积 |
|---|---|---|
| 静态二进制（Go、Rust） | `scratch` / `gcr.io/distroless/static-debian12` | 0–2MB |
| 通用、体积小 | `alpine:3.19` | ~7MB |
| 需要 glibc / Debian 软件包 | `debian:bookworm-slim` | ~75MB |
| Python | `python:3.12-slim` | ~130MB |
| Node.js | `node:20-bookworm-slim` | ~200MB |

以上是解压后的大小，随版本和 CPU 架构不同会有出入。

需要注意三点：

- **Alpine 用的是 musl 而不是 glibc。** 大多数软件不受影响，但预编译的二进制、部分 Python wheel 和 DNS 解析行为可能不同。为了省几 MB 把 Python 或 Node 应用换成 Alpine 之前，先看看 [Alpine 那个坑](https://suzf.net/zh/blog/posts/dockerfile-pitfalls-guide/#坑-7alpine-镜像的-dns-和-glibc-问题)。
- **Distroless 镜像没有 shell，也没有包管理器。** 这正是它的意义，攻击者没有工具可用；但这也意味着该阶段不能 `RUN`，也没法 `docker exec … sh` 进去排查。调试阶段可以先用 `:debug` 变体。
- **不要用 `latest`，也不要不写标签。** `FROM node` 拿到的是今天早上刚发布的版本，同一个提交构建两次可能得到不同的镜像。至少固定到主版本和次版本（`node:20.18-bookworm-slim`），第 12 节会更进一步。

## 3. 合理利用构建缓存

Docker 会缓存每条指令的结果，只要指令和它的输入没变就直接复用。对 `COPY` 来说，输入是被复制文件的校验和。一旦某一步没命中缓存，它后面的所有步骤都要重新执行。所以要按变化频率从低到高排列指令：

```dockerfile
FROM node:20-bookworm-slim
WORKDIR /app

# 依赖清单很少变：这一层和下面的安装会一直命中缓存
COPY package.json package-lock.json ./
RUN npm ci

# 源码每次提交都会变：只有从这里开始的步骤会重跑
COPY . .
RUN npm run build
```

如果在 `npm ci` 之前就 `COPY . .`，任何文件的改动（哪怕只是 README）都会让依赖安装失效，每次构建都要重新下载整个 `node_modules`。

**缓存挂载**更进一步。在 BuildKit 下，`RUN` 可以挂载一个在多次构建之间保留、但不会进入镜像的缓存目录：

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=cache,target=/root/.npm npm ci
```

即使 lock 文件变了、`npm ci` 必须重跑，大部分包也能直接从挂载的缓存里拿到，不用重新下载。`pip`（`/root/.cache/pip`）、Go（`/root/.cache/go-build` 和 `/go/pkg/mod`）、`apt` 等都可以这样用。

**在 CI 里**，每个任务往往跑在一台全新的机器上，缓存是空的。可以把缓存导出到镜像仓库，下一次再导入：

```bash
docker buildx build \
  --cache-from type=registry,ref=registry.example.com/app:buildcache \
  --cache-to   type=registry,ref=registry.example.com/app:buildcache,mode=max \
  -t registry.example.com/app:1.4.2 --push .
```

## 4. 减少镜像层数和体积

每条 `RUN`、`COPY`、`ADD` 都会生成一层，而层只会让镜像变大：在后面的层里删除文件只是把它隐藏起来，字节仍然留在前面那一层里。所以下载后要清理的东西，必须在**同一条 `RUN`** 里清理：

```dockerfile
# ❌ 软件包列表在后面的层里才删除，仍然会进入镜像
RUN apt-get update
RUN apt-get install -y curl
RUN rm -rf /var/lib/apt/lists/*

# ✅ 一层完成：更新、安装、清理
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*
```

`--no-install-recommends` 阻止 apt 安装“推荐”的软件包，这些包常常让安装量翻倍。每种包管理器都有不留缓存的写法：

| 包管理器 | 安装且不留缓存 |
|---|---|
| apt | `apt-get install -y --no-install-recommends …`，然后 `rm -rf /var/lib/apt/lists/*` |
| apk | `apk add --no-cache …` |
| dnf / yum | `dnf install -y … && dnf clean all` |
| pip | `pip install --no-cache-dir …` |
| npm | `npm ci --omit=dev`，然后 `npm cache clean --force` |

想知道体积到底花在哪里，`docker history <image>` 会列出每一层的大小，[dive](https://github.com/wagoodman/dive) 可以逐层浏览文件。

不过，把所有命令塞进一条巨大的 `RUN` 并不是目标，那样会毁掉缓存。按“一起变化的放在一起”来分组（系统包一步、应用依赖一步），清理工作和制造垃圾的那一步放在一起。

## 5. 不要以 root 运行

如果不做设置，容器里的进程就以 root 身份运行。容器虽然有隔离，但一个通过内核或运行时漏洞逃逸出来的 root 进程，在宿主机上也是 root；即使没有逃逸，它也能改写自己文件系统里的任何东西。创建一个非特权用户并切换过去：

```dockerfile
# 基于 Debian / Ubuntu 的镜像
RUN groupadd --system --gid 10001 app && \
    useradd --system --uid 10001 --gid app --no-create-home app

# 基于 Alpine 的镜像
RUN addgroup -S -g 10001 app && adduser -S -u 10001 -G app app

COPY --chown=app:app . /app
USER 10001
```

需要注意的细节：

- **`USER` 里用数字 UID。** Kubernetes 的 `runAsNonRoot` 只能校验数字用户；写成 `USER app` 时它无法判断 `app` 是不是 root，会拒绝启动 Pod。
- **绑定 1024 以下的端口需要 root。** 容器内监听 8080，在外部映射到 80。
- **应用要写的文件得有正确的属主**：用 `COPY --chown`，或者在创建数据目录的同一层里 `chown`。
- 很多官方镜像已经自带用户：`node` 镜像有 `node` 用户（UID 1000），distroless 镜像有 `:nonroot` 标签（UID 65532）。

## 6. 使用 .dockerignore

`docker build .` 在执行任何指令之前，会先把整个目录（构建上下文）发送给构建器。没有 `.dockerignore` 的话，`.git`、`node_modules`、本地构建产物和 `.env` 文件都会被发过去。这会拖慢每次构建；这些文件一变就让缓存失效（`COPY . .` 会把它们复制进去）；还可能把密钥打进镜像。

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

# 以 ! 开头表示例外
!.env.example
```

匹配规则遵循 Go 的 `filepath.Match`，`**` 匹配任意层目录。如果构建一开始就很慢（“transferring context: 900MB”），首先要检查的就是 `.dockerignore`。

## 7. COPY vs ADD

```dockerfile
# ✅ COPY 只复制文件，不做别的
COPY app.tar.gz /app/

# ⚠️ ADD 还会解压本地 tar 包，并且能下载 URL
ADD app.tar.gz /app/
```

`ADD` 有一些从字面上看不出来的额外行为：本地的 `.tar`、`.tar.gz` 等压缩包会被解压到目标位置，而远程 URL 会被下载，但**不会**解压。看到 `ADD config.tar.gz /etc/app/` 的人，必须知道这条规则才能明白最终落盘的是什么。

默认用 `COPY`。只有确实想解压本地压缩包时才用 `ADD`。需要下载文件时，优先用 `RUN` + `curl` 并校验校验和，或者在较新的 Dockerfile 前端里用 `ADD --checksum=sha256:…`，这样文件被悄悄替换时构建会失败。

## 8. ENTRYPOINT vs CMD

`ENTRYPOINT` 指定容器运行的程序，`CMD` 提供它的默认参数，可以被 `docker run` 覆盖：

```dockerfile
ENTRYPOINT ["python", "app.py"]
CMD ["--port", "8080"]
```

```bash
docker run myapp                 # python app.py --port 8080
docker run myapp --port 9090     # python app.py --port 9090
```

只写 `CMD` 时，`docker run` 镜像名后面的内容会替换整条命令，适合“工具箱”式而不是单一程序的镜像。

**始终使用 exec 格式**（`["可执行文件", "参数"]`）。shell 格式（`ENTRYPOINT python app.py`）会让你的程序作为 `/bin/sh -c` 的子进程运行。shell 成了 PID 1，而它不会转发信号：`docker stop` 发出的 SIGTERM 到了 shell 那里，应用根本收不到，10 秒后 Docker 只能用 SIGKILL 强杀。没有优雅退出，缓冲区没刷盘，连接没关闭。

如果需要启动脚本，在脚本最后用 `exec "$@"`，让真正的进程替换掉 shell，直接接收信号：

```sh
#!/bin/sh
set -e
# ... 准备配置、等待依赖 ...
exec "$@"
```

如果应用会派生子进程，还需要回收它们：用 `docker run --init` 或 [tini](https://github.com/krallin/tini) 作为 PID 1（见[僵尸进程那个坑](https://suzf.net/zh/blog/posts/dockerfile-pitfalls-guide/#坑-12僵尸进程问题)）。

## 9. 健康检查

进程在运行，不代表服务可用。`HEALTHCHECK` 告诉 Docker 如何在容器内部检测应用：

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1
```

Docker 会按设定的频率执行这条命令，把容器标记为 `healthy` 或 `unhealthy`，在 `docker ps` 里可以看到。至于标记之后会发生什么，取决于谁在管理容器：

- **Docker Compose** 可以用 `depends_on: { app: { condition: service_healthy } }` 让其他服务等它健康后再启动。
- **Docker Swarm** 会替换不健康的任务。
- **单纯的 `docker run`** 只报告状态，**不会**自动重启不健康的容器。
- **Kubernetes 完全忽略 `HEALTHCHECK`。** 它用的是 Pod 配置里的 liveness、readiness 和 startup 探针，这些也要单独定义。

检查命令必须在镜像里存在：slim 镜像常常没有 `curl`，distroless 镜像连 shell 都没有。可以用镜像里已有的工具（Alpine 上的 `wget`），往镜像里加一个很小的健康检查程序，或者干脆不写 `HEALTHCHECK`，交给编排系统的探针。

## 10. 安全扫描

镜像会继承基础镜像和所装软件包里的所有已知漏洞。每次构建后都要扫描，平时也要定期扫描，因为没有任何改动的镜像也会被新公布的漏洞命中：

```bash
# Trivy：发现高危或严重漏洞时让任务失败
trivy image --exit-code 1 --severity HIGH,CRITICAL myapp:1.4.2

# Docker Scout
docker scout cves myapp:1.4.2
```

Dockerfile 本身也要检查。[hadolint](https://github.com/hadolint/hadolint) 适合放在 CI 里，[Dockerfile 检查器](https://suzf.net/zh/tools/dockerfile-linter)在浏览器里给出同类的反馈。大多数问题靠前面几节就能解决：更小的基础镜像（第 2 节）和更少的软件包（第 4 节），意味着一开始就少了很多漏洞。

## 11. 不要让密钥留在镜像层里

构建期间接触过镜像文件系统的任何东西都会留在某一层里，即使后面的步骤把它删掉也一样；`ARG` 和 `ENV` 的值还会出现在 `docker history` 里。所以，用 `--build-arg NPM_TOKEN=…` 传入、或者以 `.npmrc` 复制进去的私有仓库令牌，任何能拉取镜像的人都能读到。

BuildKit 的 secret 挂载能让文件只在某一条 `RUN` 里可见，而不会写入任何一层：

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
```

```bash
docker build --secret id=npmrc,src=$HOME/.npmrc -t myapp .
```

构建时需要克隆私有 Git 仓库的话，`RUN --mount=type=ssh` 可以用同样的方式转发 SSH agent。运行时的密钥（数据库密码、API key）根本不应该进镜像：在容器启动时通过环境变量或挂载文件传入。密钥是怎么泄露的，见[硬编码密钥那个坑](https://suzf.net/zh/blog/posts/dockerfile-pitfalls-guide/#坑-6在镜像中硬编码密钥)。

## 12. 固定版本，让构建可复现

同一个提交构建两次，应该得到同样的镜像。每一个浮动的版本都会破坏这一点：基础镜像标签会移动，`apt-get install curl` 装的是当时最新的版本，`npm install` 会无视 lock 文件。

- **基础镜像**：`node:20.18-bookworm-slim` 这样的标签仍然会因为补丁更新而原地变化。要完全可复现，再加上摘要：`FROM node:20.18-bookworm-slim@sha256:…`。Renovate 或 Dependabot 会在新摘要发布时自动提 PR，安全更新照样能拿到，只是经过了评审。
- **应用依赖**：提交 lock 文件，并使用严格遵守它的安装命令：`npm ci`、固定版本的 `pip install -r requirements.txt`（或者你所用工具的 lock 文件）、带 `go.sum` 的 `go mod download`。
- **系统软件包**：给每个 apt 包都固定版本通常得不偿失，旧版本会从镜像源里消失。固定基础镜像摘要已经能带来大部分可复现性。

## 13. 综合示例

一个用上了以上所有做法的 Node.js 服务：

```dockerfile
# syntax=docker/dockerfile:1

# 只安装生产依赖
FROM node:20.18-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev

# 带开发依赖构建
FROM node:20.18-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npm run build

# 运行阶段：没有 shell、没有包管理器、非 root（UID 65532）
FROM gcr.io/distroless/nodejs20-debian12:nonroot
WORKDIR /app
COPY --from=deps  /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
EXPOSE 8080
CMD ["dist/server.js"]
```

各部分的作用：

- **三个阶段**（第 1 节）：开发依赖和构建工具不会进入运行镜像。
- **先复制依赖清单，再复制源码**（第 3 节）：改代码只会重跑 `COPY . .` 和构建；lock 文件变化时，npm 缓存挂载能加快安装。
- **distroless `:nonroot` 运行镜像**（第 2、5 节）：没有可被利用的 shell 和包管理器，进程以 UID 65532 运行。distroless Node 镜像的入口已经是 `node`，所以 `CMD` 只需写脚本路径，并使用 exec 格式（第 8 节）。
- **没有 `HEALTHCHECK`**：distroless 镜像里没有 shell 和 `wget`，健康检查交给编排系统的探针（第 9 节）。
- **固定版本**（第 12 节）：生产环境再加上 `@sha256:…` 摘要。

再配上 `.dockerignore`（第 6 节）、`npm ci` 需要访问私有仓库时的 secret 挂载（第 11 节），以及 CI 里的扫描（第 10 节），本文的所有做法就都覆盖到了。
