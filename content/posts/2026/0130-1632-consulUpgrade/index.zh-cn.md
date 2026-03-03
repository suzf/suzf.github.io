---
title: "consul server upgrade"
slug: "consul server upgrade"
date: 2026-01-30T16:32:53+08:00
author: "Jeffrey Su"
description: ""
categories: ["技能矩阵"]
tags: ["consul","test"]
toc: true
lightgallery: true
draft: false
---

升级 Consul 集群需要遵循 “分步走、先 Server 后 Client、保持兼容性” 的原则。如果版本跨度过大（例如从 1.1x 直接升到 1.2x），直接升级可能会导致 Raft 协议不兼容或数据损坏。

以下是详细的升级路线图和操作规程：

<!--more-->

### 1. 升级前的核心准则

- **版本跨度限制：** 非 LTS（长期支持）版本建议 **一次最多跨越 2 个次要版本**（例如：1.18 → 1.20）。如果版本极老，需按照官方提供的中间节点版本逐步升级。
  
- **备份、备份、再备份：** 在动任何节点前，执行快照备份： `consul snapshot save backup_name.snap`
  
- **顺序：** 永远先升级 **Server** 节点，再升级 **Client** 节点。
  

---

### 2. Server 集群滚动升级步骤 (Rolling Upgrade)

Server 端的升级必须保证 **Quorum (法定人数)** 不丢失，否则集群会陷入选举死循环。

1. **确认当前 Leader：** 使用 `consul operator raft list-peers` 找到当前的 Leader。
  
2. **先升级 Follower 节点：**
  
  - 选一个 Follower 节点，先执行 `consul leave`（优雅退出）。
    
  - 替换旧的 Consul 二进制文件。
    
  - 启动新版本 Consul。
    
  - **确认健康：** 查看日志并确认该节点已重新加入集群且同步了索引（`commit_index` 与 Leader 接近）。
    
  - 重复此步骤，直到所有 Follower 都升级完成。
    
3. **最后升级 Leader：**
  
  - 在旧 Leader 上执行 `consul leave`，这会强制集群触发一次新的选举，选出已升级的新版本 Follower 作为新 Leader。
    
  - 按照同样的方法替换旧 Leader 的版本并启动。
    

---

### 3. Kubernetes (Helm) 模式下的升级

如果你在 K8s 上运行 Consul，可以利用 `updatePartition` 实现精细化滚动：

1. **修改 `values.yaml`：** 将镜像版本改为目标版本。
  
2. **设置分区更新：** 为了安全，可以先设置 `server.updatePartition: 3`（假设有 3 个副本），这样 Helm 不会立刻自动更新所有 Pod。
  
3. **手动逐个滚动：** 通过逐个减小 `updatePartition` 的值（3 → 2 → 1 → 0），手动触发每一个 Server Pod 的重启和版本替换。
  

---


### 4. 常见故障处理

- **脑裂/无 Leader：** 如果升级后无法选出 Leader，请检查各节点的 `Raft Protocol` 版本是否一致（通过 `consul info` 查看）。
  
- **同步失败：** 如果新节点无法同步数据，检查磁盘空间和数据目录（`data_dir`）的权限是否在重启后发生了变化。
  

---
