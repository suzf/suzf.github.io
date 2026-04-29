---
title: "OpenClaw Must-Have Skills — Highly Recommended"
slug: "openclaw must have skills"
date: 2026-03-31T22:41:40+08:00
author: "Jeffrey Su"
description: ""
categories: ["Skills Matrix"]
tags: ["openclaw", "ai"]
toc: true
lightgallery: true
draft: false
---

The OpenClaw Skills ecosystem (ClawHub) has surpassed 13,000 skill packages, but quality varies wildly. A February 2026 security audit flagged ~13.4% for critical issues. This post recommends genuinely useful Skills by use case, helping you avoid the minefield.

<!--more-->

### Installation

All Skills are installed via the `clawhub` command:

```bash
# Install an official Skill
clawhub install openclaw/github

# Install a community Skill
clawhub install community/obsidian-claw

# View installed Skills
openclaw skills installed

# Search
openclaw skills search "keyword"
```

> ⚠️ Always check author reputation, star count, and source code before installing community Skills. 341 malicious Skills were found stealing user data on ClawHub.

---

### 🏆 Top 10 Must-Install Skills

| Rank | Skill | Category | Install | Status |
|------|-------|----------|---------|--------|
| 1 | **GitHub** | Development | `clawhub install openclaw/github` | 🟢 Stable |
| 2 | **Web Browsing** | Research | Built-in | 🟢 Stable |
| 3 | **GOG** | Productivity | `clawhub install openclaw/gog` | 🟢 Stable |
| 4 | **Tavily** | Research | `clawhub install framix-team/openclaw-tavily` | 🟢 Stable |
| 5 | **Gmail** | Productivity | Built-in | 🟢 Stable |
| 6 | **Calendar** | Productivity | Built-in | 🟢 Stable |
| 7 | **Slack** | Communication | `clawhub install steipete/slack` | 🟡 Beta |
| 8 | **n8n** | Automation | `clawhub install community/n8n-openclaw` | 🟡 Beta |
| 9 | **Obsidian** | Productivity | `clawhub install community/obsidian-claw` | 🟡 Beta |
| 10 | **Home Assistant** | Smart Home | `clawhub install openclaw/homeassistant` | 🟡 Beta |

---

### 🔧 Developer Essentials

#### GitHub (#1, Score 72/80)

The highest-rated Skill in the OpenClaw ecosystem. Supports PR creation, code review, issue management, and branch operations — complete Git workflows through conversation.

```bash
clawhub install openclaw/github
```

Typical usage:
```
"Review the latest PR on my repo and summarize the changes"
"Create a new issue for the login bug with reproduction steps"
```

#### Security-check (#12, Score 60/80)

Automatically scans project dependencies and code for security vulnerabilities, integrated with CVE databases.

```bash
clawhub install community/security-check
```

#### Linear (#14, Score 59/80)

Integrates with Linear project management — create/update issues and check sprint progress through conversation.

```bash
clawhub install community/linear-claw
```

#### Cron-backup (#20, Score 57/80)

Scheduled backups of OpenClaw configuration and memory data to prevent data loss.

```bash
clawhub install community/cron-backup
```

---

### 🔍 Search & Research

#### Tavily (#4, Score 67/80)

A search engine API designed specifically for AI Agents. Returns structured results — faster and more precise than Web Browsing. Requires a [Tavily API Key](https://tavily.com).

```bash
clawhub install framix-team/openclaw-tavily
```

#### Web Browsing (#2, Built-in)

OpenClaw's foundational capability — lets the Agent browse pages, extract content, and follow links. Most workflows depend on this.

#### Felo Search (#15, Score 59/80)

Multi-language search engine integration with strong CJK language support.

```bash
clawhub install community/felo-search
```

---

### 📋 Productivity

#### GOG (#3, Score 68/80)

"Get Organized with GOG" — task planning and goal tracking. Helps the Agent break complex tasks into executable steps. Top 3 in download count.

```bash
clawhub install openclaw/gog
```

#### Obsidian (#9, Score 62/80)

Integrates with Obsidian notes — the Agent can read/write your knowledge base, create notes, and search existing content.

```bash
clawhub install community/obsidian-claw
```

#### Notion (#13, Score 59/80)

Read/write operations on Notion databases and pages. Great for teams using Notion for project management.

```bash
clawhub install community/notion-claw
```

#### Summarize (#19, Score 58/80)

Long document/webpage summarization with a high security score (9/10). Ideal for processing large amounts of reading material.

```bash
clawhub install community/summarize
```

---

### 🤖 Automation

#### n8n (#8, Score 63/80)

Connects OpenClaw with the n8n workflow engine for cross-platform automation. Example: receive email → analyze content → create Jira issue → notify Slack.

```bash
clawhub install community/n8n-openclaw
```

#### Browser Automation (#16, Score 58/80)

Playwright-based browser automation — fill forms, click buttons, take screenshots, handle sites requiring login.

```bash
clawhub install community/browser-automation
```

#### Home Assistant (#10, Score 61/80)

Control smart home devices through conversation. "Turn off the living room lights." "Set the AC to 24°C."

```bash
clawhub install openclaw/homeassistant
```

---

### 🧠 AI/ML Advanced

#### Capability Evolver (#11, Score 60/80)

Enables the Agent to self-improve — analyzes failed tasks and automatically adjusts strategies. Extremely high learning value (LRN 9/10).

```bash
clawhub install community/capability-evolver
```

#### RAG Pipeline (#38, Score 51/80)

Adds Retrieval-Augmented Generation to OpenClaw — build vector indexes on local documents and retrieve relevant context.

```bash
clawhub install community/rag-pipeline
```

---

### 📊 Data Processing

#### Firecrawl (#18, Score 58/80)

Structured web scraping with pagination support, JavaScript rendering, and clean Markdown/JSON output.

```bash
clawhub install community/firecrawl
```

#### DuckDB CRM (#28, Score 55/80)

Lightweight local CRM powered by DuckDB. Manage contacts and customer data with SQL — all data stays local.

```bash
clawhub install community/duckdb-crm
```

---

### Recommended Combos by Role

#### Software Engineer

```bash
clawhub install openclaw/github
clawhub install community/security-check
clawhub install community/n8n-openclaw
```

#### Researcher / Knowledge Worker

```bash
clawhub install framix-team/openclaw-tavily
clawhub install community/obsidian-claw
clawhub install community/summarize
```

#### Project Manager

```bash
clawhub install openclaw/gog
clawhub install community/notion-claw
clawhub install community/todoist-claw
```

#### Content Creator

```bash
clawhub install community/image-generation
clawhub install community/felo-slides
clawhub install community/youtube-digest
```

---

### Security Reminders

1. **Only install Skills you need** — each Skill has access to your data
2. **Prefer official Skills** (`openclaw/` prefix) and high-star community Skills
3. **Review source code before installing** — pay attention to network requests and file access
4. **Use Skill Vetter** — a community-built security scanner:
   ```bash
   clawhub install community/skill-vetter
   openclaw run "Scan the skill community/xxx for security issues"
   ```
5. **Configure least privilege** — restrict `allowed_paths` and `denied_paths` in `~/.openclaw/config.yaml`

---

### 🔒 Security Auditing

#### Skill Vetter (Rating 4.9/5, 695 Stars)

**Install this before installing anything else.** A security-first vetting protocol that enforces a standardized checklist before any third-party Skill installation. It's a docs-only Skill — zero executable code, zero permissions required.

```bash
clawhub install openclaw/skill-vetter
```

The vetting protocol has 4 steps:

1. **Source Check** — Author reputation, star count, last update date
2. **Code Review (MANDATORY)** — File-by-file inspection for red flags:
   - curl/wget to unknown URLs
   - Reading `~/.ssh`, `~/.aws`, `~/.config`
   - `eval()`/`exec()` with external input
   - base64 decoding, obfuscated code, sudo requests
   - Accessing browser cookies/sessions
3. **Permission Scope Analysis** — Are file reads/writes, commands, and network access minimal?
4. **Risk Classification** — Four-tier system:

| Risk Level | Examples | Action |
|-----------|----------|--------|
| 🟢 Low | Notes, weather, formatting | Basic review, install OK |
| 🟡 Medium | File ops, browser, APIs | Full code review required |
| 🔴 High | Credentials, trading, system | Human approval required |
| ⛔ Extreme | Security configs, root access | Do NOT install |

Produces a standardized report with red flag detection results, permission inventory, and final verdict (✅ Safe / ⚠️ Caution / ❌ Do Not Install).

> Trust hierarchy: Official Skills > High-star repos (1000+) > Known authors > Unknown sources > Skills requesting credentials (always require human approval)

---

### 🧬 Self-Evolution

#### Self-Improvement (v2, 2.6k Downloads)

Enables the Agent to learn from mistakes and continuously improve. It captures errors, user corrections, feature requests, and learnings into structured Markdown files for future sessions to reference.

```bash
clawdhub install self-improving-agent
```

How it works:

- **Automatic detection triggers** — Logs automatically when commands fail, users correct output, APIs break, or knowledge is outdated
- **Structured logging** — Categorized storage in the `.learnings/` directory:
  ```
  .learnings/
  ├── LEARNINGS.md          # Corrections, knowledge gaps, best practices
  ├── ERRORS.md             # Command failures, exceptions, timeouts
  └── FEATURE_REQUESTS.md   # User-requested capabilities
  ```
- **Learning promotion** — When a learning recurs (≥3 times, across 2+ tasks, within 30 days), it's automatically promoted to project-level memory files:
  - `SOUL.md` — Behavioral guidelines
  - `AGENTS.md` — Workflow improvements
  - `TOOLS.md` — Tool usage gotchas
- **Cross-session communication** — Share learnings between sessions via `sessions_send`
- **Automatic Skill extraction** — When a learning is generic enough, it can be extracted into a standalone reusable Skill

Typical scenario:
```
Agent first time: runs npm install → fails
Agent logs: project uses pnpm, not npm
Agent second time: runs pnpm install → succeeds
```

> Supports OpenClaw, Claude Code, Codex CLI, GitHub Copilot, and other Agent platforms.

---

For more Skills, check the [ClawHub Marketplace](https://clawhub.com) and [OpenClaw Top 50 Skills](https://tenten.co/openclaw/en/docs/top-50-skills/overview).
