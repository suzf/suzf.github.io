---
title: "consul server upgrade"
slug: "consul server upgrade"
date: 2026-01-30T16:32:53+08:00
author: "Jeffrey Su"
description: ""
categories: ["Skills Matrix"]
tags: ["consul"]
toc: true
lightgallery: true
draft: false
---

Upgrading a Consul cluster must follow the principle of "step by step, Servers before Clients, maintain compatibility". If the version gap is too large (e.g., jumping from 1.1x directly to 1.2x), a direct upgrade may cause Raft protocol incompatibility or data corruption.

Below is a detailed upgrade roadmap and procedure:

<!--more-->

### 1. Core Principles Before Upgrading

- **Version gap limit:** For non-LTS versions, it is recommended to **skip no more than 2 minor versions at a time** (e.g., 1.18 → 1.20). For very old versions, follow the official intermediate version path for step-by-step upgrades.

- **Backup, backup, backup:** Before touching any node, take a snapshot: `consul snapshot save backup_name.snap`

- **Order:** Always upgrade **Server** nodes first, then **Client** nodes.

---

### 2. Server Cluster Rolling Upgrade

Server upgrades must maintain **Quorum** at all times, otherwise the cluster will enter an election loop.

1. **Identify the current Leader:** Use `consul operator raft list-peers` to find the current Leader.

2. **Upgrade Follower nodes first:**

  - Pick a Follower node and run `consul leave` (graceful exit).

  - Replace the old Consul binary.

  - Start the new version of Consul.

  - **Verify health:** Check logs and confirm the node has rejoined the cluster and synced its index (`commit_index` close to the Leader's).

  - Repeat for all remaining Followers.

3. **Upgrade the Leader last:**

  - Run `consul leave` on the old Leader. This forces a new election, promoting an already-upgraded Follower to Leader.

  - Replace the old Leader's binary and start it using the same procedure.

---

### 3. Upgrading in Kubernetes (Helm)

If you run Consul on K8s, you can use `updatePartition` for fine-grained rolling upgrades:

1. **Update `values.yaml`:** Change the image version to the target version.

2. **Set partition update:** For safety, set `server.updatePartition: 3` (assuming 3 replicas) so Helm won't automatically update all Pods at once.

3. **Roll manually:** Decrease `updatePartition` one at a time (3 → 2 → 1 → 0), triggering each Server Pod to restart with the new version.

---

### 4. Common Troubleshooting

- **Split-brain / No Leader:** If no Leader can be elected after the upgrade, check whether the `Raft Protocol` version is consistent across all nodes (use `consul info`).

- **Sync failure:** If a new node fails to sync data, check disk space and whether permissions on the data directory (`data_dir`) changed after the restart.

---
