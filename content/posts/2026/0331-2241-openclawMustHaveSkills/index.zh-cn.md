---
title: "OpenClaw 必备 Skills 强烈推荐"
slug: "openclaw must have skills"
date: 2026-03-31T22:41:40+08:00
author: "Jeffrey Su"
description: ""
categories: ["技能矩阵"]
tags: ["openclaw", "ai"]
toc: true
lightgallery: true
draft: false
---

OpenClaw 的 Skills 生态（ClawHub）已经超过 13000 个技能包，但质量参差不齐。2026 年 2 月的安全审计显示约 13.4% 存在安全问题。本文从实际使用出发，按场景推荐真正值得安装的 Skills，帮你避开雷区。

<!--more-->

### 安装方式

所有 Skills 通过 `clawhub` 命令安装：

```bash
# 安装官方 Skill
clawhub install openclaw/github

# 安装社区 Skill
clawhub install community/obsidian-claw

# 查看已安装
openclaw skills installed

# 搜索
openclaw skills search "keyword"
```

> ⚠️ 安装社区 Skill 前务必检查作者信誉、Star 数和源码。ClawHub 上曾发现 341 个恶意 Skill 窃取用户数据。

---

### 🏆 Top 10 必装 Skills

| 排名 | Skill | 分类 | 安装命令 | 状态 |
|------|-------|------|---------|------|
| 1 | **GitHub** | 开发 | `clawhub install openclaw/github` | 🟢 稳定 |
| 2 | **Web Browsing** | 搜索 | 内置 | 🟢 稳定 |
| 3 | **GOG** | 效率 | `clawhub install openclaw/gog` | 🟢 稳定 |
| 4 | **Tavily** | 搜索 | `clawhub install framix-team/openclaw-tavily` | 🟢 稳定 |
| 5 | **Gmail** | 效率 | 内置 | 🟢 稳定 |
| 6 | **Calendar** | 效率 | 内置 | 🟢 稳定 |
| 7 | **Slack** | 通讯 | `clawhub install steipete/slack` | 🟡 Beta |
| 8 | **n8n** | 自动化 | `clawhub install community/n8n-openclaw` | 🟡 Beta |
| 9 | **Obsidian** | 效率 | `clawhub install community/obsidian-claw` | 🟡 Beta |
| 10 | **Home Assistant** | 智能家居 | `clawhub install openclaw/homeassistant` | 🟡 Beta |

---

### 🔧 开发者必备

#### GitHub（排名 #1，评分 72/80）

OpenClaw 生态中评分最高的 Skill。支持 PR 创建、代码审查、Issue 管理、分支操作，直接在对话中完成 Git 工作流。

```bash
clawhub install openclaw/github
```

典型用法：
```
"Review the latest PR on my repo and summarize the changes"
"Create a new issue for the login bug with reproduction steps"
```

#### Security-check（排名 #12，评分 60/80）

自动扫描项目依赖和代码中的安全漏洞，集成 CVE 数据库。

```bash
clawhub install community/security-check
```

#### Linear（排名 #14，评分 59/80）

与 Linear 项目管理工具集成，在对话中创建/更新 Issue、查看 Sprint 进度。

```bash
clawhub install community/linear-claw
```

#### Cron-backup（排名 #20，评分 57/80）

定时备份 OpenClaw 配置和记忆数据，防止数据丢失。

```bash
clawhub install community/cron-backup
```

---

### 🔍 搜索与研究

#### Tavily（排名 #4，评分 67/80）

专为 AI Agent 设计的搜索引擎 API，返回结构化结果，比 Web Browsing 更快更精准。需要 [Tavily API Key](https://tavily.com)。

```bash
clawhub install framix-team/openclaw-tavily
```

#### Web Browsing（排名 #2，内置）

OpenClaw 的基础能力，让 Agent 能浏览网页、提取内容、跟踪链接。没有它，大多数工作流都无法运行。

#### Felo Search（排名 #15，评分 59/80）

多语言搜索引擎集成，对中文搜索支持较好。

```bash
clawhub install community/felo-search
```

---

### 📋 效率与生产力

#### GOG（排名 #3，评分 68/80）

"Get Organized with GOG" — 任务规划和目标追踪，帮助 Agent 将复杂任务拆解为可执行的步骤。下载量排名前三。

```bash
clawhub install openclaw/gog
```

#### Obsidian（排名 #9，评分 62/80）

与 Obsidian 笔记集成，Agent 可以读写你的知识库、创建笔记、搜索已有内容。

```bash
clawhub install community/obsidian-claw
```

#### Notion（排名 #13，评分 59/80）

Notion 数据库和页面的读写操作，适合用 Notion 做项目管理的团队。

```bash
clawhub install community/notion-claw
```

#### Summarize（排名 #19，评分 58/80）

长文档/网页摘要生成，安全评分高（9/10），适合处理大量阅读材料。

```bash
clawhub install community/summarize
```

---

### 🤖 自动化

#### n8n（排名 #8，评分 63/80）

将 OpenClaw 与 n8n 工作流引擎打通，实现跨平台自动化。例如：收到邮件 → 分析内容 → 创建 Jira Issue → 通知 Slack。

```bash
clawhub install community/n8n-openclaw
```

#### Browser Automation（排名 #16，评分 58/80）

基于 Playwright 的浏览器自动化，可以填表、点击、截图，处理需要登录的网站。

```bash
clawhub install community/browser-automation
```

#### Home Assistant（排名 #10，评分 61/80）

通过对话控制智能家居设备。"关掉客厅的灯" "把空调调到 24 度"。

```bash
clawhub install openclaw/homeassistant
```

---

### 🧠 AI/ML 进阶

#### Capability Evolver（排名 #11，评分 60/80）

让 Agent 能自我改进——分析失败的任务并自动调整策略。学习价值极高（LRN 9/10）。

```bash
clawhub install community/capability-evolver
```

#### RAG Pipeline（排名 #38，评分 51/80）

为 OpenClaw 添加检索增强生成能力，可以对本地文档建立向量索引并检索。

```bash
clawhub install community/rag-pipeline
```

---

### 📊 数据处理

#### Firecrawl（排名 #18，评分 58/80）

结构化网页爬取，支持分页、JavaScript 渲染，输出干净的 Markdown/JSON。

```bash
clawhub install community/firecrawl
```

#### DuckDB CRM（排名 #28，评分 55/80）

基于 DuckDB 的轻量级本地 CRM，用 SQL 管理联系人和客户数据，数据完全本地化。

```bash
clawhub install community/duckdb-crm
```

---

### 按角色推荐组合

#### 软件工程师

```bash
clawhub install openclaw/github
clawhub install community/security-check
clawhub install community/n8n-openclaw
```

#### 研究员 / 知识工作者

```bash
clawhub install framix-team/openclaw-tavily
clawhub install community/obsidian-claw
clawhub install community/summarize
```

#### 项目经理

```bash
clawhub install openclaw/gog
clawhub install community/notion-claw
clawhub install community/todoist-claw
```

#### 内容创作者

```bash
clawhub install community/image-generation
clawhub install community/felo-slides
clawhub install community/youtube-digest
```

---

### 安全提醒

1. **只安装你需要的 Skill** — 每个 Skill 都有权限访问你的数据
2. **优先选择官方 Skill**（`openclaw/` 前缀）和高 Star 社区 Skill
3. **安装前检查源码** — 特别关注网络请求和文件访问
4. **使用 Skill Vetter** — 社区开发的安全扫描工具，安装前先扫一遍：
   ```bash
   clawhub install community/skill-vetter
   openclaw run "Scan the skill community/xxx for security issues"
   ```
5. **配置最小权限** — 在 `~/.openclaw/config.yaml` 中限制 `allowed_paths` 和 `denied_paths`

---

### 🔒 安全审计

#### Skill Vetter（评分 4.9/5，695 Stars）

**装 Skill 之前必须先装这个。** 这是一个安全审计协议，在安装任何第三方 Skill 之前执行标准化的安全检查。纯文档 Skill，零可执行代码，零权限要求。

```bash
clawhub install openclaw/skill-vetter
```

审计流程分 4 步：

1. **来源检查** — 作者信誉、Star 数、最后更新时间
2. **代码审查（强制）** — 逐文件检查红线行为：
   - curl/wget 到未知 URL
   - 读取 `~/.ssh`、`~/.aws`、`~/.config`
   - 使用 `eval()`/`exec()` 执行外部输入
   - base64 解码、混淆代码、sudo 请求
   - 访问浏览器 cookie/session
3. **权限范围分析** — 文件读写、命令执行、网络访问是否最小化
4. **风险分级** — 四级分类：

| 风险等级 | 示例 | 操作 |
|---------|------|------|
| 🟢 低 | 笔记、天气、格式化 | 基本审查后安装 |
| 🟡 中 | 文件操作、浏览器、API | 完整代码审查 |
| 🔴 高 | 凭证、交易、系统操作 | 需人工审批 |
| ⛔ 极高 | 安全配置、root 权限 | 禁止安装 |

审计完成后会生成标准化报告，包含红线检测结果、权限清单和最终裁定（✅ 安全 / ⚠️ 谨慎安装 / ❌ 禁止安装）。

> 信任层级：官方 Skill > 高 Star 仓库（1000+）> 已知作者 > 未知来源 > 请求凭证的 Skill（必须人工审批）

---

### 🧬 自我进化

#### Self-Improvement（v2，2.6k 下载）

让 Agent 从错误中学习、持续改进。它将错误、用户纠正、功能请求和经验教训记录到结构化的 Markdown 文件中，供后续 session 参考。

```bash
clawdhub install self-improving-agent
```

工作原理：

- **自动检测触发** — 命令失败、用户纠正、API 报错、知识过时时自动记录
- **结构化日志** — 分类存储到 `.learnings/` 目录：
  ```
  .learnings/
  ├── LEARNINGS.md          # 纠正、知识盲区、最佳实践
  ├── ERRORS.md             # 命令失败、异常、超时
  └── FEATURE_REQUESTS.md   # 用户请求的新功能
  ```
- **经验晋升** — 当某个经验被反复触发（≥3 次，跨 2 个以上任务，30 天内），自动提升到项目级记忆文件：
  - `SOUL.md` — 行为准则
  - `AGENTS.md` — 工作流改进
  - `TOOLS.md` — 工具使用注意事项
- **跨 session 通信** — 通过 `sessions_send` 在不同 session 间共享经验
- **自动提取 Skill** — 当某个经验足够通用时，可以自动提取为独立的可复用 Skill

典型场景：
```
Agent 第一次：用 npm install 安装依赖 → 失败
Agent 记录：项目用 pnpm，不是 npm
Agent 第二次：直接用 pnpm install → 成功
```

> 支持 OpenClaw、Claude Code、Codex CLI、GitHub Copilot 等多种 Agent 平台。

---

更多 Skills 信息参考 [ClawHub 官方市场](https://clawhub.com) 和 [OpenClaw Top 50 Skills](https://tenten.co/openclaw/en/docs/top-50-skills/overview)。
