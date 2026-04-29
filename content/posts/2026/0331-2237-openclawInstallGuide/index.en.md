---
title: "OpenClaw Step-by-Step Installation Guide"
slug: "openclaw install guide"
date: 2026-03-31T22:37:32+08:00
author: "Jeffrey Su"
description: ""
categories: ["Skills Matrix"]
tags: ["openclaw", "ai"]
toc: true
lightgallery: true
draft: false
---

OpenClaw is an open-source, self-hosted AI assistant platform (formerly Clawdbot / Moltbot) that supports both cloud and local models. This guide walks you through installation, configuration, and your first run from scratch.

<!--more-->

### 1. System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | macOS 13+ / Ubuntu 22.04+ / Windows 11 (WSL2) | macOS 14+ or Ubuntu 24.04 |
| Node.js | 22.16+ | **24.x** |
| RAM | 4 GB | 8 GB+ |
| Disk | 2 GB | 5 GB |
| Container Engine | Docker 24+ or Podman 5+ | Podman 5+ (recommended) |

> ⚠️ OpenClaw heavily uses features introduced in Node.js 22.16. Older versions will cause unpredictable errors.

---

### 2. Install Node.js

Use nvm (Node Version Manager) for easy version management:

```bash
# Install nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc  # or source ~/.zshrc

# Install Node.js 24
nvm install 24
nvm use 24

# Verify
node --version  # Should display v24.x.x
```

---

### 3. Install OpenClaw

#### Option 1: npm (Recommended)

```bash
npm install -g @openclaw/cli
openclaw --version
```

#### Option 2: Homebrew (macOS)

```bash
brew tap openclaw/tap
brew install openclaw
```

#### Option 3: Build from Source

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw
npm install
npm run build
npm link
openclaw --version
```

#### Option 4: Docker

```bash
docker pull openclaw/openclaw:latest
docker run --rm openclaw/openclaw:latest --version
```

---

### 4. Install a Container Engine

OpenClaw's skill sandbox requires a container engine. Podman is recommended (rootless, smaller attack surface):

```bash
# macOS
brew install podman
podman machine init
podman machine start

# Ubuntu / Debian
sudo apt install -y podman

# If you prefer Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in for group change to take effect
```

---

### 5. Initialize and Verify

```bash
# Initialize (creates config directory)
openclaw init

# Expected output:
# 🦞 OpenClaw initialized!
# Config directory: ~/.openclaw/
# Gateway port: 18789
# Container engine: podman

# Health check
openclaw doctor

# Expected output:
# ✓ Node.js v24.x.x
# ✓ Podman 5.x.x (rootless)
# ✓ Gateway port 18789 available
# ✓ Config directory ~/.openclaw/ exists
# ✓ Memory system initialized
# All checks passed!
```

---

### 6. Configure AI Model

Edit `~/.openclaw/config.yaml`:

#### Cloud Models (API Key Required)

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

> For better security, inject API keys via environment variables:
> ```bash
> export ANTHROPIC_API_KEY=sk-ant-your-key-here
> # Or
> export OPENAI_API_KEY=sk-your-key-here
> ```

#### Local Models (Ollama, Fully Free & Offline)

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model (choose based on your hardware)
ollama pull llama3.1:8b          # 8GB+ RAM
ollama pull deepseek-coder-v2:33b # 24GB+ RAM, best for coding
ollama pull llama3.1:70b          # 48GB+ RAM, best overall
```

Config:

```yaml
model:
  provider: ollama
  model: llama3.1:8b
  base_url: http://localhost:11434
```

Start Ollama and use OpenClaw — no API key needed.

---

### 7. Security Configuration (Important!)

The OpenClaw Gateway listens on port 18789 by default. **Ensure it only binds to localhost:**

```bash
cat ~/.openclaw/gateway.yaml
```

```yaml
gateway:
  port: 18789
  bind: "127.0.0.1"    # ✅ Correct: localhost only
  # bind: "0.0.0.0"    # ❌ Dangerous: exposed to the network
```

> ⚠️ CVE-2026-25253 allows remote code execution through an exposed port 18789.

Add firewall rules as an extra layer of defense:

```bash
# ufw
sudo ufw deny 18789/tcp

# iptables
sudo iptables -A INPUT -p tcp --dport 18789 -j DROP
sudo iptables -A INPUT -p tcp -s 127.0.0.1 --dport 18789 -j ACCEPT
```

---

### 8. First Run

```bash
# Simple test
openclaw run "List all files in the current directory"

# Code generation
openclaw run "Create a Python script that validates email addresses"

# Multi-step task
openclaw run "Find all TODO comments in this project and create a summary report"
```

---

### 9. Windows Installation (WSL2)

OpenClaw **does not support native Windows**. Use WSL2:

```powershell
# PowerShell (Administrator)
wsl --install -d Ubuntu-24.04
```

```bash
# Enter WSL2 Ubuntu
wsl

# Install Node.js
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc
nvm install 24

# Install OpenClaw
npm install -g @openclaw/cli
openclaw init
```

If WSL2 runs out of memory, create `.wslconfig` in your Windows user directory:

```ini
# C:\Users\YourUsername\.wslconfig
[wsl2]
memory=8GB
swap=4GB
```

---

### 10. Troubleshooting

**`command not found`:**
```bash
# npm global bin directory not in PATH
npm config get prefix
echo 'export PATH="$PATH:'$(npm config get prefix)'/bin"' >> ~/.bashrc
source ~/.bashrc
```

**`npm install -g` permission denied:**
```bash
# Don't use sudo! Use nvm to manage Node.js to avoid permission issues
# Or change the npm global directory
mkdir ~/.npm-global
npm config set prefix '~/.npm-global'
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

**Podman Machine won't start (macOS):**
```bash
podman machine rm
podman machine init --cpus 2 --memory 4096
podman machine start
```

**Agent stuck in a loop:**
- Lower `max_iterations` (set to 10-15)
- Switch to a more capable model
- Make your prompt more specific — avoid vague instructions

---

### 11. Directory Structure

```
~/.openclaw/
├── gateway.yaml          # Gateway configuration
├── soul.md               # AI personality definition
├── providers/            # LLM provider configuration
│   └── default.yaml
├── channels/             # Messaging platform connections
├── skills/               # Installed skills
│   └── .cache/
├── memory/               # Memory system data
│   ├── wal/              # Write-Ahead Log
│   └── compacted/        # Compacted long-term memory
└── logs/                 # Runtime logs
```

---

### 12. Quick Command Reference

```bash
openclaw run "your task"          # Execute a task
openclaw run --dry-run "task"     # Plan without executing
openclaw run --verbose "task"     # Detailed logging
openclaw history                  # View execution history
openclaw config                   # Show current configuration
openclaw skills list              # List available skills
openclaw skills install web-scraper  # Install a skill
openclaw doctor                   # Health check
```

---

For more information, see the [OpenClaw official repository](https://github.com/openclaw/openclaw).
