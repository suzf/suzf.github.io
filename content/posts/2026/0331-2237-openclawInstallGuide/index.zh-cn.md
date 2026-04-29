---
title: "OpenClaw 保姆级安装教程"
slug: "openclaw install guide"
date: 2026-03-31T22:37:32+08:00
author: "Jeffrey Su"
description: ""
categories: ["技能矩阵"]
tags: ["openclaw", "ai"]
toc: true
lightgallery: true
draft: false
---

OpenClaw 是一个开源的自托管 AI 助手平台（前身为 Clawdbot / Moltbot），支持云端模型和本地模型。本文从零开始，手把手带你完成安装、配置和第一次运行。

<!--more-->

### 1. 环境要求

| 组件 | 最低要求 | 推荐 |
|------|---------|------|
| 操作系统 | macOS 13+ / Ubuntu 22.04+ / Windows 11 (WSL2) | macOS 14+ 或 Ubuntu 24.04 |
| Node.js | 22.16+ | **24.x** |
| RAM | 4 GB | 8 GB+ |
| 磁盘 | 2 GB | 5 GB |
| 容器引擎 | Docker 24+ 或 Podman 5+ | Podman 5+（推荐） |

> ⚠️ OpenClaw 大量使用 Node.js 22.16 引入的特性，旧版本会出现不可预测的错误。

---

### 2. 安装 Node.js

推荐使用 nvm 管理 Node.js 版本：

```bash
# 安装 nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc  # 或 source ~/.zshrc

# 安装 Node.js 24
nvm install 24
nvm use 24

# 验证
node --version  # 应显示 v24.x.x
```

---

### 3. 安装 OpenClaw

#### 方式一：npm 安装（推荐）

```bash
npm install -g @openclaw/cli
openclaw --version
```

#### 方式二：Homebrew（macOS）

```bash
brew tap openclaw/tap
brew install openclaw
```

#### 方式三：从源码构建

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw
npm install
npm run build
npm link
openclaw --version
```

#### 方式四：Docker

```bash
docker pull openclaw/openclaw:latest
docker run --rm openclaw/openclaw:latest --version
```

---

### 4. 安装容器引擎

OpenClaw 的技能沙箱依赖容器引擎。推荐 Podman（无需 root 权限，攻击面更小）：

```bash
# macOS
brew install podman
podman machine init
podman machine start

# Ubuntu / Debian
sudo apt install -y podman

# 如果你更习惯 Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# 重新登录使组变更生效
```

---

### 5. 初始化与验证

```bash
# 初始化（创建配置目录）
openclaw init

# 输出示例：
# 🦞 OpenClaw initialized!
# Config directory: ~/.openclaw/
# Gateway port: 18789
# Container engine: podman

# 健康检查
openclaw doctor

# 预期输出：
# ✓ Node.js v24.x.x
# ✓ Podman 5.x.x (rootless)
# ✓ Gateway port 18789 available
# ✓ Config directory ~/.openclaw/ exists
# ✓ Memory system initialized
# All checks passed!
```

---

### 6. 配置 AI 模型

编辑 `~/.openclaw/config.yaml`：

#### 使用云端模型（需要 API Key）

```yaml
model:
  provider: anthropic          # openai / anthropic / google
  model: claude-sonnet-4-6
  api_key: sk-ant-your-key-here

agent:
  max_iterations: 25
  timeout: 300
  memory: conversation
```

> 更安全的做法是通过环境变量注入 API Key：
> ```bash
> export ANTHROPIC_API_KEY=sk-ant-your-key-here
> # 或
> export OPENAI_API_KEY=sk-your-key-here
> ```

#### 使用本地模型（Ollama，完全免费离线）

```bash
# 安装 Ollama
curl -fsSL https://ollama.com/install.sh | sh

# 拉取模型（根据硬件选择）
ollama pull llama3.1:8b          # 8GB+ RAM
ollama pull deepseek-coder-v2:33b # 24GB+ RAM，编程最佳
ollama pull llama3.1:70b          # 48GB+ RAM，综合最强
```

配置文件：

```yaml
model:
  provider: ollama
  model: llama3.1:8b
  base_url: http://localhost:11434
```

启动 Ollama 后即可使用，无需 API Key。

---

### 7. 安全配置（重要！）

OpenClaw Gateway 默认监听 18789 端口，**必须确保只绑定到 localhost**：

```bash
cat ~/.openclaw/gateway.yaml
```

```yaml
gateway:
  port: 18789
  bind: "127.0.0.1"    # ✅ 正确：仅本地访问
  # bind: "0.0.0.0"    # ❌ 危险：暴露到公网
```

> ⚠️ CVE-2026-25253 允许攻击者通过暴露的 18789 端口远程执行代码。

额外加一层防火墙：

```bash
# ufw
sudo ufw deny 18789/tcp

# iptables
sudo iptables -A INPUT -p tcp --dport 18789 -j DROP
sudo iptables -A INPUT -p tcp -s 127.0.0.1 --dport 18789 -j ACCEPT
```

---

### 8. 第一次运行

```bash
# 简单测试
openclaw run "列出当前目录下的所有文件"

# 代码生成
openclaw run "Create a Python script that validates email addresses"

# 多步骤任务
openclaw run "Find all TODO comments in this project and create a summary report"
```

---

### 9. Windows 用户安装指南 (WSL2)

OpenClaw **不支持原生 Windows**，必须通过 WSL2：

```powershell
# PowerShell（管理员）
wsl --install -d Ubuntu-24.04
```

```bash
# 进入 WSL2 Ubuntu
wsl

# 安装 Node.js
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc
nvm install 24

# 安装 OpenClaw
npm install -g @openclaw/cli
openclaw init
```

如果 WSL2 内存不足，在 Windows 用户目录创建 `.wslconfig`：

```ini
# C:\Users\你的用户名\.wslconfig
[wsl2]
memory=8GB
swap=4GB
```

---

### 10. 常见问题

**`command not found`：**
```bash
# npm 全局目录不在 PATH 中
npm config get prefix
echo 'export PATH="$PATH:'$(npm config get prefix)'/bin"' >> ~/.bashrc
source ~/.bashrc
```

**`npm install -g` 权限不足：**
```bash
# 不要用 sudo！改用 nvm 管理 Node.js 即可避免权限问题
# 或者修改 npm 全局目录
mkdir ~/.npm-global
npm config set prefix '~/.npm-global'
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

**Podman Machine 启动失败（macOS）：**
```bash
podman machine rm
podman machine init --cpus 2 --memory 4096
podman machine start
```

**Agent 陷入死循环：**
- 降低 `max_iterations`（设为 10-15）
- 换用更强的模型
- 让 prompt 更具体，避免模糊指令

---

### 11. 目录结构说明

```
~/.openclaw/
├── gateway.yaml          # Gateway 配置
├── soul.md               # AI 人格定义
├── providers/            # LLM 提供商配置
│   └── default.yaml
├── channels/             # 消息平台连接
├── skills/               # 已安装的技能
│   └── .cache/
├── memory/               # 记忆系统数据
│   ├── wal/              # Write-Ahead Log
│   └── compacted/        # 压缩后的长期记忆
└── logs/                 # 运行日志
```

---

### 12. 常用命令速查

```bash
openclaw run "你的任务"          # 执行任务
openclaw run --dry-run "任务"    # 只规划不执行
openclaw run --verbose "任务"    # 详细日志
openclaw history                 # 查看执行历史
openclaw config                  # 查看当前配置
openclaw skills list             # 列出可用技能
openclaw skills install web-scraper  # 安装技能
openclaw doctor                  # 健康检查
```

---

更多信息参考 [OpenClaw 官方文档](https://github.com/openclaw/openclaw)。
