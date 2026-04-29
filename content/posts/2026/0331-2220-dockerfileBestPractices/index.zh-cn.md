---
title: "Dockerfile 最佳实践"
slug: "dockerfile best practices"
date: 2026-03-31T22:20:51+08:00
author: "Jeffrey Su"
description: ""
categories: ["技能矩阵"]
tags: ["docker", "devops"]
toc: true
lightgallery: true
draft: false
---

一个写得好的 Dockerfile 能显著减小镜像体积、加快构建速度、提升安全性。本文总结日常工作中最实用的 Dockerfile 编写规范。

<!--more-->

### 1. 使用多阶段构建 (Multi-stage Build)

将编译环境和运行环境分离，最终镜像只包含运行所需的产物：

```dockerfile
# 编译阶段
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o server .

# 运行阶段
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/server /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["server"]
```

效果：Go 编译镜像 ~1GB → 最终镜像 ~20MB。

---

### 2. 选择合适的基础镜像

| 场景 | 推荐镜像 | 大小 |
|------|---------|------|
| 通用 | `alpine:3.19` | ~7MB |
| 静态二进制 | `scratch` / `gcr.io/distroless/static` | 0~2MB |
| Debian 需求 | `debian:bookworm-slim` | ~80MB |
| Python | `python:3.12-slim` | ~150MB |

> 避免使用 `latest` 标签，始终锁定具体版本以保证构建可复现。

---

### 3. 合理利用构建缓存

Docker 按层缓存，**变化频率低的指令放前面**：

```dockerfile
FROM node:20-alpine
WORKDIR /app

# 先复制依赖文件（变化少）
COPY package.json package-lock.json ./
RUN npm ci --production

# 再复制源码（变化频繁）
COPY . .
RUN npm run build
```

如果先 `COPY . .` 再 `npm install`，每次代码改动都会重新安装依赖。

---

### 4. 减少镜像层数和体积

```dockerfile
# ❌ 多个 RUN 产生多层
RUN apt-get update
RUN apt-get install -y curl
RUN rm -rf /var/lib/apt/lists/*

# ✅ 合并为一层，并清理缓存
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*
```

关键点：
- `--no-install-recommends` 避免安装不必要的包
- 同一层内清理缓存，否则删除操作不会减小镜像体积

---

### 5. 不要以 root 运行

```dockerfile
RUN addgroup -S app && adduser -S app -G app
USER app
```

以非 root 用户运行容器，降低容器逃逸后的攻击面。

---

### 6. 使用 .dockerignore

在项目根目录创建 `.dockerignore`，避免将无关文件发送到构建上下文：

```
.git
node_modules
*.md
.env
.DS_Store
dist
coverage
```

构建上下文越小，`docker build` 启动越快。

---

### 7. COPY vs ADD

```dockerfile
# ✅ 优先使用 COPY（行为明确）
COPY app.tar.gz /app/

# ⚠️ ADD 会自动解压 tar 并支持 URL，行为隐式
ADD app.tar.gz /app/
```

只在需要自动解压 tar 时使用 `ADD`，其他场景一律用 `COPY`。

---

### 8. ENTRYPOINT vs CMD

```dockerfile
# ENTRYPOINT 定义容器的主进程
# CMD 提供默认参数，可被 docker run 覆盖
ENTRYPOINT ["python", "app.py"]
CMD ["--port", "8080"]
```

```bash
# 使用默认参数
docker run myapp
# 等价于: python app.py --port 8080

# 覆盖参数
docker run myapp --port 9090
# 等价于: python app.py --port 9090
```

> 始终使用 exec 格式 `["executable", "param"]`，避免 shell 格式导致信号无法正确传递。

---

### 9. 健康检查

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1
```

配合编排工具（Docker Compose / Kubernetes）实现自动重启不健康的容器。

---

### 10. 安全扫描

构建完成后扫描镜像漏洞：

```bash
# Trivy
trivy image myapp:latest

# Docker Scout
docker scout cves myapp:latest
```

建议集成到 CI/CD Pipeline 中，阻断含高危漏洞的镜像发布。

---
