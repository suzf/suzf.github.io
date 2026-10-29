---
title: "Dockerfile 避坑指南"
slug: "dockerfile pitfalls guide"
date: 2026-03-31T22:23:03+08:00
author: "Jeffrey Su"
description: "生产环境里 12 个常见的 Dockerfile 坑，每个都讲清楚你会看到的现象、原因、修复方法和检查方式：apt 缓存过期、shell 格式 ENTRYPOINT、密钥泄露、Alpine 的 musl、缺少 CA 证书、VOLUME、时区、缓存失效和僵尸进程。"
categories: ["技能矩阵"]
tags: ["docker", "devops"]
toc: true
draft: false
---

大多数 Dockerfile 错误不会让构建失败。镜像能构建，容器能启动，问题要到后面才冒出来：每次发布都要等十秒才能停掉容器、只在生产环境出现的 TLS 报错、日志时间差了八个小时、任何能拉取镜像的人都能读到的密码。本文整理了我遇到最多的 12 个坑，每个都写明：你实际会看到的现象、为什么会这样、怎么修、怎么检查。文末有一张“现象 → 坑”的对照表，排查问题时可以直接查。

<!--more-->

想检查自己的 Dockerfile 有没有踩到这些坑，可以把它粘贴到我做的免费 [Dockerfile 检查器](https://suzf.net/zh/tools/dockerfile-linter)。它在浏览器里运行，每条结果都会链接回下文对应的那个坑。

## 坑 1：apt-get update 和 install 分开写

```dockerfile
# ❌ update 那一层会被单独缓存
RUN apt-get update
RUN apt-get install -y curl

# ✅ 更新、安装、清理放在同一层
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
```

**现象：** Dockerfile 写好几周后，有人往安装列表里加了一个包，构建就报 `404 Not Found` 或 `Unable to locate package`；或者装上的是带已知漏洞的旧版本。

**原因：** Docker 按命令文本缓存每条 `RUN`。`RUN apt-get update` 的文本从来不变，所以它那一层（带着第一次构建那天的软件包索引）会被永远复用。安装那行变了，只有安装这一步重跑，用的却是过期的索引，而索引里指向的旧版本早已从镜像源删除。

**修复：** `apt-get update` 一定要和安装写在同一条 `RUN` 里，这样软件包列表一变，索引也会一起刷新。在同一步里删除 `/var/lib/apt/lists/*`：索引有 20–40MB，在最终镜像里毫无用处。`apk update`（改用 `apk add --no-cache`）和 `yum`/`dnf`（`dnf install -y … && dnf clean all`）也是同理。

## 坑 2：COPY . . 放在 RUN install 之前

```dockerfile
# ❌ 任何文件改动都会让依赖安装失效
COPY . .
RUN pip install -r requirements.txt

# ✅ 先复制依赖清单，再复制源码
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
```

**现象：** 改一行代码，构建就要重新下载安装所有依赖，本该 30 秒的构建要花五分钟。

**原因：** `COPY` 的缓存键是所复制的所有文件的校验和。`COPY . .` 复制了全部文件，任何改动（哪怕是 README）都会让它没命中缓存，后面的步骤（包括安装依赖）全部重跑。

**修复：** 先只复制安装依赖需要的文件（`requirements.txt`、`package.json` + `package-lock.json`、`go.mod` + `go.sum`、`Gemfile` + `Gemfile.lock`），安装，再复制其余文件。这样只要依赖列表不变，安装那一层就一直能复用。关于缓存挂载（即使安装必须重跑也能加速），见[构建缓存](https://suzf.net/zh/blog/posts/dockerfile-best-practices/#3-合理利用构建缓存)。

## 坑 3：用 shell 格式写 ENTRYPOINT

```dockerfile
# ❌ shell 格式：实际执行 /bin/sh -c "python app.py"，PID 1 是 sh
ENTRYPOINT python app.py

# ✅ exec 格式：python 直接作为 PID 1 运行
ENTRYPOINT ["python", "app.py"]
```

**现象：** `docker stop`、滚动发布或删除 Kubernetes Pod 时，总是正好要等 10 秒（或者配置的宽限期），应用也从来没打印过退出日志，正在处理的请求被直接切断。

**原因：** shell 格式下，Docker 启动的是 `/bin/sh -c "…"`，你的应用是它的子进程。停止容器时 SIGTERM 发给 PID 1，也就是 shell，而 shell 不会转发信号。应用一直运行到宽限期结束，内核再发 SIGKILL，这个信号无法被捕获或处理。

**修复：** `ENTRYPOINT` 和 `CMD` 都用 exec 格式（JSON 数组）。如果需要包装脚本，在脚本最后用 `exec "$@"`（或 `exec python app.py`），让真正的进程替换掉 shell。

exec 格式有两件事不做：不展开变量（`["echo", "$HOME"]` 会原样输出 `$HOME`），也不解析 `&&`、管道等 shell 语法。需要这些时，写进一个以 `exec` 结尾的脚本里。

**检查：** `docker exec <容器> ps -o pid,comm`（镜像里有 `ps` 的话）。PID 1 应该是你的应用或 tini 这类 init，而不是 `sh`。

## 坑 4：在 RUN 中设置环境变量

```dockerfile
# ❌ 每条 RUN 都是新的 shell，export 到下一步就没了
RUN export APP_HOME=/opt/app
RUN cd $APP_HOME   # $APP_HOME 为空，实际执行的是 "cd"，进了 /root

# ✅ ENV 在后续步骤和运行时都有效
ENV APP_HOME=/opt/app
WORKDIR $APP_HOME
```

**现象：** 后面的步骤在错误的目录里执行，或者缺了某个设置，而且往往不报错，因为空变量展开后什么都没有。

**原因：** 每条 `RUN` 都启动一个新的 shell 进程。在某一步里 export 的变量和 `cd` 的目录，都会随这个 shell 退出而消失。

**修复：** 按你需要的生命周期选择指令：

| 你想要 | 用 |
|---|---|
| 在后续构建步骤**和**运行时都可用的变量 | `ENV NAME=value` |
| 只在构建期间使用的值（版本号、开关） | `ARG NAME=value` |
| 只对一条命令生效的变量 | `RUN NAME=value command` |
| 切换目录 | `WORKDIR /path`（不要用 `RUN cd`） |

不要用 `ARG` 或 `ENV` 传密钥：两者都会出现在 `docker history` 里（见坑 6）。

## 坑 5：忽略 .dockerignore 导致镜像臃肿

没有 `.dockerignore` 时，`docker build .` 会把整个目录发给构建器，`COPY . .` 再把它们全部放进镜像：

```text
.git/           # 常常比代码本身还大
node_modules/   # 是为你笔记本的系统和 CPU 编译的
.env            # 真实的凭证
*.log
dist/
coverage/
```

**现象：** 构建在 “transferring context” 上花很久，镜像比应用大得多，或者应用在容器里因为原生模块报错崩溃（`invalid ELF header`、`… was compiled against a different Node.js version`）。

**原因：** 源码只有几 MB 的项目，Git 历史轻松就有几百 MB。本地 `node_modules` 里在 macOS 上编译的原生模块，会覆盖镜像里安装的那份，在 Linux 上跑不起来。复制进镜像层的 `.env` 文件，任何能拉取镜像的人都能读到。

**修复：** 在 Dockerfile 旁边加一个 `.dockerignore`。最佳实践一文里有[完整示例](https://suzf.net/zh/blog/posts/dockerfile-best-practices/#6-使用-dockerignore)。

**检查：** BuildKit 构建的输出开头会显示上下文大小（`transferring context: 2.1MB`）。如果很大，先搞清楚里面是什么。

## 坑 6：在镜像中硬编码密钥

```dockerfile
# ❌ 被打进镜像：docker history 和镜像层里都能看到
ENV DB_PASSWORD=my_secret_password
ARG NPM_TOKEN
RUN echo "password=my_secret_password" > /app/config
RUN rm /app/config   # 太晚了：文件仍在上一层里

# ✅ 运行时密钥在容器启动时从环境传入
#    docker run -e DB_PASSWORD=... myapp   （或 Kubernetes Secret、Vault 等）
# ✅ 构建期密钥用 BuildKit secret 挂载
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
```

**现象：** 通常没有任何现象，直到被密钥扫描工具或攻击者发现。任何能拉取镜像的人都能读到它。

**原因：** 镜像是一叠层，每一层都是任何有拉取权限的人都能解开的 tar 包。在后面的层里删除文件只是把它隐藏起来。`ENV` 和 `ARG` 的值存在镜像配置里，`docker history --no-trunc` 会直接打印出来。

**修复：** 运行时的密钥在容器启动时传入（环境变量、挂载文件、密钥管理服务）。构建期需要的密钥（比如私有仓库令牌）用 [BuildKit secret 挂载](https://suzf.net/zh/blog/posts/dockerfile-best-practices/#11-不要让密钥留在镜像层里)，它不会把密钥写进任何一层。

**如果密钥已经随镜像发出去了**，只是去掉密钥重新构建还不够：旧镜像的每一份副本（镜像仓库、缓存、各人的电脑）里都还有它。按已泄露处理并立即更换；[密码生成器](https://suzf.net/zh/tools/password-generator)可以生成一个足够强的随机密码。

**检查：** `docker history --no-trunc <镜像>` 会显示每条 `ENV`、`ARG` 和 `RUN` 命令。`trivy image --scanners secret` 这类扫描工具会检查镜像层里的内容。

## 坑 7：alpine 镜像的 DNS 和 glibc 问题

```dockerfile
# ❌ 在 glibc 系统上编译的二进制，复制到基于 musl 的 Alpine
FROM alpine:3.19
COPY myapp /usr/local/bin/
CMD ["myapp"]
# exec /usr/local/bin/myapp: no such file or directory
```

**现象：** 容器启动后立刻退出，报 `no such file or directory`，可 `ls` 明明能看到这个文件。

**原因：** Alpine 用的是 musl libc 而不是 glibc。在 Debian、Ubuntu 或 `golang` 镜像里编译的动态链接二进制，会让内核去找 glibc 的加载器（`/lib64/ld-linux-x86-64.so.2`），而 Alpine 上没有它。“找不到的文件”是加载器，不是你的程序。在宿主机上 `file myapp` 会显示 `dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2`。

**修复：**
- Go：用 `CGO_ENABLED=0` 编译，得到能在任何地方运行（包括 `scratch`）的静态二进制。
- 在基于 Alpine 的镜像里编译（`golang:1.22-alpine`、`rust:alpine`），让二进制链接 musl。
- 或者这个应用干脆不用 Alpine：`debian:bookworm-slim` 或 distroless 都基于 glibc，只是稍大一些。

**DNS：** musl 的解析器行为也和 glibc 不同。musl 1.2.4（Alpine 3.18）之前，DNS 响应被截断时不会改用 TCP 重试，应答较大的域名就会解析失败。它还会并行查询所有 nameserver，处理 `search` 域的方式也不一样，在 Kubernetes 里表现为解析慢或时好时坏。请使用 Alpine 3.18 及以上版本；如果仍然遇到奇怪的解析错误，先把同一个应用放到 Debian 镜像上试一下，再深入排查。

Python 和 Node 也有同样的 musl 问题：很多预编译的 wheel 和 npm 原生模块只提供 glibc 版本，在 Alpine 上要么从源码编译（慢，还需要构建工具），要么直接失败。对这两种语言，slim 版 Debian 镜像通常是更划算的选择。

## 坑 8：多阶段构建忘记复制运行时依赖

```dockerfile
FROM golang:1.22 AS builder
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /server .

FROM alpine:3.19
COPY --from=builder /server /usr/local/bin/server
# ❌ 本地好好的，到了生产环境：
#    x509: certificate signed by unknown authority
#    unknown time zone Asia/Shanghai

# ✅ 安装程序运行时需要的东西
RUN apk add --no-cache ca-certificates tzdata
```

**现象：** 应用正常启动，然后在第一次 HTTPS 请求、第一次时区转换或第一次调用共享库时失败。

**原因：** 运行阶段只包含你放进去的东西。编译镜像里有 CA 证书、时区数据库和共享库，精简的运行镜像里可能一样都没有，而在用到它们的代码路径执行之前，什么都不会报错。

**修复：** 列出二进制运行时需要的东西，显式加进去：

| 缺少 | 现象 | 添加 |
|---|---|---|
| CA 证书 | `x509: certificate signed by unknown authority` | `ca-certificates`；`scratch` 镜像用 `COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/` |
| 时区数据 | `unknown time zone`，或者时间悄悄变成 UTC | `tzdata`；Go 可以 `import _ "time/tzdata"` 把它嵌进二进制 |
| 共享库 | `error while loading shared libraries: libxyz.so` | 对应的软件包，或者静态链接 |
| 用户数据库 | `user: unknown userid` | 在 `/etc/passwd` 里加条目，或者 `USER` 用数字 |

**检查：** 对动态链接的二进制，在运行镜像里执行 `ldd /usr/local/bin/server` 能列出缺失的库。另外在 CI 里让镜像跑一遍真实的工作负载（包括一次对外的 HTTPS 请求），而不只是检查“能不能启动”。

## 坑 9：VOLUME 指令的隐式行为

```dockerfile
# ⚠️ 这次写入会怎样，取决于构建器和容器的运行方式
VOLUME /data
RUN echo "init" > /data/config
```

**现象：** Dockerfile 放进某个目录的文件，运行时不见了，而且只在某些机器上、或者只在 Kubernetes 里出现。或者 `docker volume ls` 里堆了几百个没人有意创建的匿名卷。

**原因：** `VOLUME` 不只是标注一个路径：

- **构建结果不一致。** 在 `VOLUME` 那行**之后**写入该路径的文件，旧版构建器会丢掉，BuildKit 会保留，同一份 Dockerfile 构建出不同的镜像。
- **挂载会盖住镜像内容。** 容器启动时，Docker 会把镜像里该路径下的文件复制到一个**新建的空卷**里，所以看起来没问题。但 bind mount、已经有数据的命名卷或 Kubernetes 卷会**盖在**这个路径上，镜像原有的内容就被挡住了。
- **每次 `docker run` 都会新建一个匿名卷**，除非你显式挂载。删除容器时它们不会一起删除（除非用 `docker run --rm` 或 `docker rm -v`），于是越积越多。
- **无法撤销。** 以你的镜像为 `FROM` 的镜像会继承这个 `VOLUME`，而且没有任何指令能去掉它。

**修复：** 文件要在 `VOLUME` 那行之前写好；更好的做法是让 entrypoint 脚本在首次启动、目录为空时再创建默认文件，这对任何类型的挂载都有效。很多团队干脆不在 Dockerfile 里写 `VOLUME`，而是在真正决定存储的地方（Compose、Kubernetes）声明卷。

## 坑 10：构建时的时区和 locale 问题

```dockerfile
# ❌ 没有时区数据库时，只设置 TZ 不起作用
ENV TZ=Asia/Shanghai

# ✅ Alpine：安装 tzdata，TZ 才能被解析
RUN apk add --no-cache tzdata
ENV TZ=Asia/Shanghai

# ✅ Debian/Ubuntu：C.UTF-8 是内置的，不用装包
ENV LANG=C.UTF-8
```

**现象：** 日志时间和定时任务差了几个小时；中文文件名等非 ASCII 文本变成 `?` 或乱码；Python、Perl 打印 locale 警告。

**原因：** `TZ=Asia/Shanghai` 只是一个名字，要到 `/usr/share/zoneinfo` 里查找。Alpine、distroless/static 和部分 slim 镜像不带这个数据库，查找失败时 glibc 和 musl 会悄悄回退到 UTC。文本方面，程序遵循 `LANG`/`LC_ALL`，没有设置 UTF-8 locale 时会退回 ASCII（`POSIX`）。

**修复：**
- **时区：** 先确认时区数据库存在（`ls /usr/share/zoneinfo/Asia/Shanghai`）：在 Alpine 以及其他缺少它的镜像上安装 `tzdata`，或者把它嵌进二进制（Go：`import _ "time/tzdata"`），然后再设置 `TZ`。
- **Locale：** 在 Debian、Ubuntu 等 glibc 镜像上，`ENV LANG=C.UTF-8` 就足以正确处理 UTF-8 文本。只有需要特定语言的 locale 时才要装 `locales` 包。注意 Debian 的 `locale-gen` 读取的是 `/etc/locale.gen`，要取消注释对应的行，而不是给它传参数：

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends locales \
    && sed -i 's/^# *zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=zh_CN.UTF-8
```

很多团队更喜欢另一种做法：所有容器都用 UTC，存储和日志都用 UTC，只在展示时转换成本地时间。这样时区问题就只集中在一个转换点上。原因见 [Unix 时间戳与时区](https://suzf.net/zh/blog/posts/unix-timestamps-and-time-zones/)。

## 坑 11：docker build 缓存不生效的隐藏原因

某一步你没动过，却每次都重建；或者你以为会重建的一步，却一直用着缓存。常见原因：

- **复制了不该复制的文件。** 除非 `.dockerignore` 排除了，`COPY . .` 会把日志、编辑器临时文件和构建产物一起复制，它们的任何变化都会让这一步及之后的步骤失效（坑 2、坑 5）。
- **文件权限。** `COPY` 的缓存键包含权限位等文件元数据，所以对复制的文件 `chmod +x` 即使内容没变也会导致缓存失效。修改时间**不**在缓存键里，所以重新 `git clone` 本身不会让缓存失效。
- **`ARG` 的值变了。** 传入不同的 `--build-arg`，会从第一条用到这个参数的指令开始让缓存失效。用当前日期或提交哈希填充的构建参数（常用于加 label）会让它之后的每一步在每次构建时都重跑。这类参数要尽量晚声明。
- **缓存有效但内容过期。** 相反的问题：`RUN apt-get update` 或 `RUN git clone …` 的文本从不变化，所以会被永远缓存（坑 1）。确实需要最新结果时，用 `--no-cache` 或 `--no-cache-filter <阶段>`。
- **全新的 CI 机器。** 没有本地缓存，每一步都要重建。把缓存导出到镜像仓库（见 [CI 里的构建缓存](https://suzf.net/zh/blog/posts/dockerfile-best-practices/#3-合理利用构建缓存)）。

还有一个看起来像缓存问题的坑：`ARG` 好像丢了值：

```dockerfile
# ❌ 在 FROM 之前声明的 ARG，在阶段内部不可见
ARG VERSION=3.19
FROM alpine:$VERSION
RUN echo $VERSION   # 输出空行

# ✅ 在阶段内重新声明（不带值），把它引入作用域
ARG VERSION=3.19
FROM alpine:$VERSION
ARG VERSION
RUN echo $VERSION   # 3.19
```

第一个 `FROM` 之前的 `ARG` 只能在 `FROM` 行里使用。每个阶段开始时它们都不在作用域内，而未设置的变量会不报错地展开成空字符串，于是下载地址悄悄变成了 `app-.tgz`。

**检查：** `docker build --progress=plain .` 会在每个复用了缓存的步骤旁边打印 `CACHED`。第一个没有 `CACHED` 的步骤，就是缓存断掉的地方。

## 坑 12：僵尸进程问题

```dockerfile
# ✅ 用 tini 作为 PID 1：转发信号并回收僵尸进程
RUN apk add --no-cache tini
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["python", "app.py"]
```

**现象：** 容器里 `ps` 能看到越来越多的 `<defunct>` 进程，最后容器无法再创建新进程（`fork: Resource temporarily unavailable`）。或者明明用了 exec 格式，SIGTERM 还是不起作用。

**原因：** 在 Linux 里，PID 1 有两项特殊职责：收养孤儿进程并在它们退出时回收；而且它没有默认的信号处理，除非程序自己注册了处理函数，否则 SIGTERM 会被忽略。大多数应用都不是按 PID 1 来写的。如果应用（或 shell 脚本）会派生子进程，比如 Node 应用调用命令行工具、或者启动 Chrome 截图，结束的子进程就没人回收，一直以僵尸状态留着。

**修复：** 用一个极简的 init 作为 PID 1，由它承担这两项职责，再把你的应用作为子进程启动：

- `docker run --init` 会加上 Docker 自带的 init（tini），不用改镜像。
- 在镜像里安装 tini（Alpine 的 `apk add tini` 装在 `/sbin/tini`，Debian 的 `apt-get install tini` 装在 `/usr/bin/tini`），把它设为 `ENTRYPOINT`，这样镜像在哪里运行都有效。
- Kubernetes 没有 `--init` 参数：要么把 tini 放进镜像，要么在 Pod 上设置 `shareProcessNamespace: true`，让 pause 容器成为 PID 1 并回收僵尸进程。

如果你的应用是单个进程、从不派生子进程，并且自己处理 SIGTERM（很多 Go 服务就是这样），就不需要 init。

## 速查：现象 → 坑

| 你看到的 | 查看 |
|---|---|
| `apt-get install` 报 404 / “Unable to locate package” | 坑 1 |
| 每次改代码都要重装所有依赖 | 坑 2、坑 11 |
| `docker stop` 总是要等 10 秒 | 坑 3、坑 12 |
| 在一条 `RUN` 里设置的变量，下一条里是空的 | 坑 4 |
| “transferring context” 很慢、镜像巨大、原生模块报错 | 坑 5 |
| 密码出现在 `docker history` 里 | 坑 6 |
| 文件明明存在却报 `exec …: no such file or directory` | 坑 7 |
| `x509: certificate signed by unknown authority` | 坑 8 |
| 目录里的文件在运行时消失了 | 坑 9 |
| 时间差了几个小时，非 ASCII 文本乱码 | 坑 10 |
| `ARG` 在阶段内部是空的 | 坑 11 |
| `<defunct>` 进程越积越多 | 坑 12 |

想从一开始就避开大部分这些问题，见 [Dockerfile 最佳实践](https://suzf.net/zh/blog/posts/dockerfile-best-practices/)。
