---
title: "nomad server cluster upgrade"
slug: "nomad server cluster upgrade"
date: 2026-03-31T22:09:08+08:00
author: "Jeffrey Su"
description: ""
categories: ["Skills Matrix"]
tags: ["nomad"]
toc: true
lightgallery: true
draft: false
---

Upgrading a Nomad Server cluster follows the core principle of "backup first, rolling upgrade, Followers before Leader". Since Nomad relies on the Raft consensus protocol, Quorum must be maintained throughout the upgrade process, otherwise the cluster becomes unavailable.

Here is the detailed upgrade procedure:

<!--more-->

### 1. Pre-Upgrade Preparation

- **Version Compatibility:** Review the [Nomad Upgrade Guides](https://developer.hashicorp.com/nomad/docs/upgrade) to confirm the upgrade path. Nomad supports upgrading from the previous minor version (e.g., 1.7.x → 1.8.x). **Skipping versions is not recommended.**

- **Backup Snapshot:** Always save a Raft snapshot before upgrading:
  ```bash
  nomad operator snapshot save backup_$(date +%Y%m%d%H%M).snap
  ```

- **Check Cluster Status:** Confirm all Server nodes are healthy:
  ```bash
  nomad server members
  nomad operator raft list-peers
  ```

- **Drain Jobs on Target Node (Optional):** If the Server also runs as a Client, drain it first:
  ```bash
  nomad node drain -enable -yes <node-id>
  ```

---

### 2. Server Rolling Upgrade Steps

Using a 3-node Server cluster as an example (1 Leader + 2 Followers):

**Step 1: Identify the Leader**

```bash
nomad operator raft list-peers
```

Note the current Leader node — **upgrade it last**.

**Step 2: Upgrade Followers One by One**

For each Follower node:

```bash
# 1. Stop the nomad service
sudo systemctl stop nomad

# 2. Replace the binary
sudo cp /path/to/new/nomad /usr/local/bin/nomad
nomad version  # Verify version

# 3. Start the service
sudo systemctl start nomad

# 4. Verify the node has rejoined the cluster
nomad server members
nomad operator raft list-peers
```

Wait until the node status becomes `alive` and Raft logs are synced before upgrading the next Follower.

**Step 3: Upgrade the Leader**

After all Followers are upgraded, perform the same operation on the Leader. Stopping the Leader will trigger a new election, and an already-upgraded Follower will be elected as the new Leader — this is expected behavior.

---

### 3. Post-Upgrade Verification

```bash
# Confirm all nodes are on the same version
nomad server members

# Check cluster health
nomad operator raft list-peers

# Verify jobs are running normally
nomad status

# Check Leader logs for anomalies
journalctl -u nomad --since "10 minutes ago" --no-pager
```

---

### 4. Rollback Plan

If issues arise after the upgrade:

1. **Stop the problematic node:** `sudo systemctl stop nomad`
2. **Restore the old binary:** Replace with the previous version of the nomad binary.
3. **Restore data if needed:** Use the previously saved snapshot:
   ```bash
   nomad operator snapshot restore backup_xxx.snap
   ```
4. **Restart the node:** `sudo systemctl start nomad`

---

### 5. Common Issues

- **Unable to elect Leader after upgrade:** Check that the Raft protocol version is consistent across all nodes (`nomad agent-info | grep raft`) and ensure network connectivity is normal.

- **Job scheduling anomalies:** If evaluations pile up after the upgrade, check `nomad operator scheduler get-config` to confirm the scheduler configuration hasn't changed.

- **Client compatibility:** Upgrade Clients only after all Servers are upgraded. The Server version must be **greater than or equal to** the Client version.

---
