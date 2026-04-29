---
title: "nomad server cluster upgrade"
slug: "nomad server cluster upgrade"
date: 2026-03-31T22:09:08+08:00
author: "Jeffrey Su"
description: ""
categories: ["技能矩阵"]
tags: ["nomad"]
toc: true
lightgallery: true
draft: false
---

升级 Nomad Server 集群同样遵循 "先备份、滚动升级、先 Follower 后 Leader" 的核心原则。Nomad 基于 Raft 共识协议，升级过程中必须始终保持 Quorum，否则集群将不可用。

以下是详细的升级操作规程：

<!--more-->

### 1. 升级前准备

- **版本兼容性：** 查阅 [Nomad Upgrade Guides](https://developer.hashicorp.com/nomad/docs/upgrade) 确认目标版本的升级路径。Nomad 支持从前一个次要版本直接升级（例如 1.7.x → 1.8.x），**不建议跳版本升级**。

- **备份快照：** 升级前务必保存 Raft 快照：
  ```bash
  nomad operator snapshot save backup_$(date +%Y%m%d%H%M).snap
  ```

- **检查集群状态：** 确认所有 Server 节点健康：
  ```bash
  nomad server members
  nomad operator raft list-peers
  ```

- **排空待升级节点上的 Job（可选）：** 如果 Server 同时也跑 Client，先 drain：
  ```bash
  nomad node drain -enable -yes <node-id>
  ```

---

### 2. Server 滚动升级步骤 (Rolling Upgrade)

以 3 节点 Server 集群为例（1 Leader + 2 Follower）：

**Step 1：确认 Leader**

```bash
nomad operator raft list-peers
```

记录当前 Leader 节点，**最后升级它**。

**Step 2：逐个升级 Follower**

对每个 Follower 节点执行：

```bash
# 1. 停止 nomad 服务
sudo systemctl stop nomad

# 2. 替换二进制文件
sudo cp /path/to/new/nomad /usr/local/bin/nomad
nomad version  # 确认版本

# 3. 启动服务
sudo systemctl start nomad

# 4. 验证节点重新加入集群
nomad server members
nomad operator raft list-peers
```

等待该节点状态变为 `alive` 且 Raft 日志同步完成后，再升级下一个 Follower。

**Step 3：升级 Leader**

所有 Follower 升级完成后，对 Leader 执行相同操作。停止 Leader 会触发重新选举，已升级的 Follower 会被选为新 Leader，这是预期行为。

---

### 3. 升级后验证

```bash
# 确认所有节点版本一致
nomad server members

# 检查集群健康
nomad operator raft list-peers

# 确认 Job 运行正常
nomad status

# 查看 Leader 日志是否有异常
journalctl -u nomad --since "10 minutes ago" --no-pager
```

---

### 4. 回滚方案

如果升级后出现异常：

1. **停止问题节点：** `sudo systemctl stop nomad`
2. **恢复旧版本二进制：** 替换回旧版 nomad 二进制文件
3. **如需恢复数据：** 使用之前的快照还原：
   ```bash
   nomad operator snapshot restore backup_xxx.snap
   ```
4. **重启节点：** `sudo systemctl start nomad`

---

### 5. 常见问题

- **升级后无法选举 Leader：** 检查各节点 Raft 协议版本是否一致（`nomad agent-info | grep raft`），确保网络连通性正常。

- **Job 调度异常：** 升级后如果出现 eval 堆积，检查 `nomad operator scheduler get-config` 确认调度器配置未变化。

- **Client 兼容性：** Nomad Server 升级完成后再升级 Client。Server 版本必须 **大于等于** Client 版本。

---
