---
title: "Dockerfile 避坑指南"
slug: "dockerfile pitfalls guide"
date: 2026-03-31T22:23:03+08:00
author: "Jeffrey Su"
description: ""
categories: ["技能矩阵"]
tags: ["docker", "devops"]
toc: true
lightgallery: true
draft: false
---

写 Dockerfile 看似简单，但实际生产中有大量隐蔽的坑。本文整理了常见的 Dockerfile 踩坑场景和对应的解决方案，帮你少走弯路。

<!--more-->

### 坑 1：apt-get update 和 install 分开写

```dockerfile
# ❌ 缓存层问题：update 被缓存后，install 可能安装旧版本甚至找不到包
RUN apt-get update
RUN apt-get install -y curl

# ✅ 合并到同一层
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
```

`apt-get update` 单独一层会被缓存，后续修改 install 的包列表时不会重新执行 update，导致安装失败。

---

### 坑 2：COPY . . 放在 RUN install 之前

```dockerfile
# ❌ 任何文件改动都会让依赖安装缓存失效
COPY . .
RUN pip install -r requirements.txt

# ✅ 先复制依赖文件，再复制源码
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
```

改一行代码就要重新安装所有依赖，构建时间从 30 秒变 5 分钟。

---

### 坑 3：用 shell 格式写 ENTRYPOINT

```dockerfile
# ❌ shell 格式：进程以 /bin/sh -c 启动，PID 1 是 sh 而不是你的应用
ENTRYPOINT python app.py

# ✅ exec 格式：应用直接作为 PID 1
ENTRYPOINT ["python", "app.py"]
```

shell 格式的后果：
- `docker stop` 发送的 SIGTERM 被 sh 吞掉，应用收不到信号
- 容器停止时只能等 10 秒超时后被 SIGKILL 强杀
- 优雅退出（graceful shutdown）完全失效

---

### 坑 4：在 RUN 中设置环境变量

```dockerfile
# ❌ 每个 RUN 是独立的 shell，变量不会传递
RUN export APP_HOME=/opt/app
RUN cd $APP_HOME  # $APP_HOME 为空

# ✅ 使用 ENV 指令
ENV APP_HOME=/opt/app
RUN cd $APP_HOME && do_something
```

---

### 坑 5：忽略 .dockerignore 导致镜像臃肿

没有 `.dockerignore` 时，`COPY . .` 会把所有文件发送到 Docker daemon：

```
# 常见的被误打包的文件
.git/          # 可能几百 MB
node_modules/  # 本地依赖和容器内架构可能不同
.env           # 包含密钥，严重安全隐患
*.log
dist/
```

**真实案例：** 一个 Node.js 项目，源码 5MB，但 `.git` 目录 800MB，构建上下文传输就要 30 秒。

---

### 坑 6：在镜像中硬编码密钥

```dockerfile
# ❌ 密钥会永久留在镜像层中，即使后续删除也能通过 docker history 看到
ENV DB_PASSWORD=my_secret_password
RUN echo "password=my_secret_password" > /app/config

# ✅ 运行时注入
# docker run -e DB_PASSWORD=xxx myapp
# 或使用 Docker secrets / Vault
```

即使你在后面的层 `RUN rm /app/config`，中间层仍然包含该文件。

---

### 坑 7：alpine 镜像的 DNS 和 glibc 问题

```dockerfile
# ❌ 某些应用依赖 glibc，alpine 用的是 musl libc
FROM alpine:3.19
COPY myapp /usr/local/bin/
# 运行时报错：/lib/x86_64-linux-gnu/libc.so.6: No such file or directory
```

解决方案：
- 编译时静态链接：`CGO_ENABLED=0`（Go）
- 换用 `debian:bookworm-slim` 或 `distroless`
- alpine 下的 DNS 解析在高并发时可能有问题（musl 的 DNS 实现与 glibc 不同）

---

### 坑 8：多阶段构建忘记复制运行时依赖

```dockerfile
FROM golang:1.22 AS builder
RUN go build -o server .

FROM alpine:3.19
COPY --from=builder /go/src/app/server /usr/local/bin/
# ❌ 如果应用依赖 ca-certificates 或时区数据，运行时会报错
# TLS 请求失败：x509: certificate signed by unknown authority

# ✅ 安装运行时依赖
RUN apk add --no-cache ca-certificates tzdata
```

常见遗漏：
- `ca-certificates` — HTTPS 请求必需
- `tzdata` — 时区相关功能必需
- 动态链接库 — 如果不是静态编译

---

### 坑 9：VOLUME 指令的隐式行为

```dockerfile
# ⚠️ VOLUME 之后对该目录的修改会被丢弃
VOLUME /data
RUN echo "init" > /data/config  # 这行写入会在运行时被匿名卷覆盖
```

`VOLUME` 声明后，后续 RUN 对该路径的写入在容器启动时会被空的匿名卷覆盖。如果需要初始化数据，在 `VOLUME` 之前完成，或使用 entrypoint 脚本在运行时初始化。

---

### 坑 10：构建时的时区和 locale 问题

```dockerfile
# ❌ 容器内默认 UTC 时区，日志时间和宿主机不一致
# ❌ locale 缺失导致中文乱码

# ✅ 设置时区
ENV TZ=Asia/Shanghai
RUN apk add --no-cache tzdata

# ✅ Debian 系设置 locale
RUN apt-get update && apt-get install -y locales \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
```

---

### 坑 11：docker build 缓存不生效的隐藏原因

缓存失效的常见原因：

- **文件权限变化：** `chmod` 后文件内容没变，但权限变了，缓存失效
- **时间戳变化：** `git clone` 后文件 mtime 不同，缓存失效
- **BuildKit 和旧引擎行为不同：** `DOCKER_BUILDKIT=1` 和传统引擎的缓存策略有差异
- **ARG 在 FROM 之前：** `FROM` 之前的 `ARG` 不会传递到构建阶段

```dockerfile
# ❌ ARG 在 FROM 之前声明，FROM 之后不可用
ARG VERSION=3.19
FROM alpine:$VERSION
RUN echo $VERSION  # 空值

# ✅ FROM 之后重新声明
ARG VERSION=3.19
FROM alpine:$VERSION
ARG VERSION
RUN echo $VERSION  # 3.19
```

---

### 坑 12：僵尸进程问题

容器内 PID 1 进程不会自动回收子进程，导致僵尸进程堆积：

```dockerfile
# ✅ 使用 tini 作为 init 进程
RUN apk add --no-cache tini
ENTRYPOINT ["tini", "--"]
CMD ["python", "app.py"]
```

或者在 `docker run` 时加 `--init` 参数。

---
