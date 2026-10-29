---
title: "Rolling Upgrades for Consul and Nomad Server Clusters Without Losing Quorum"
slug: "nomad server cluster upgrade"
date: 2026-03-31T22:09:08+08:00
author: "Jeffrey Su"
description: "One playbook for upgrading Consul and Nomad servers: quorum math, snapshots, Followers before the Leader, servers before clients, Helm updatePartition, verification, rollback and common failures."
categories: ["Skills Matrix"]
tags: ["consul", "nomad"]
toc: true
draft: false
---

Consul and Nomad are both built on HashiCorp's Raft library, so upgrading their server clusters follows the same playbook: take a snapshot, replace one server at a time, leave the Leader for last, and only then touch the clients. Get the order wrong and the cluster loses quorum, stops accepting writes, and you spend the maintenance window recovering instead of upgrading.

This guide covers both tools side by side: the shared procedure, the commands that differ, upgrading Consul on Kubernetes with Helm, and how to verify and roll back.

<!--more-->

## 1. Why the order matters: quorum

A Raft cluster can only commit writes (and elect a Leader) while a majority of its servers, the **quorum**, is up and talking:

| Servers | Quorum | Failures tolerated |
|---|---|---|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

During a rolling upgrade, one server is always down. In a 3-server cluster that already uses up the single failure you can tolerate, so:

- upgrade **exactly one server at a time**, and don't start the next until the previous one is back and caught up;
- make sure every server is healthy before you begin. If one is already sick, taking a second one down for the upgrade stops the cluster;
- upgrade the **Leader last**, so the cluster goes through only one election rather than one per server.

The same quorum rule is why production clusters run 3 or 5 servers: with 5, you keep a one-failure margin even while a server is down for its upgrade.

## 2. The commands at a glance

| Task | Consul | Nomad |
|---|---|---|
| Save a snapshot | `consul snapshot save backup.snap` | `nomad operator snapshot save backup.snap` |
| Restore a snapshot | `consul snapshot restore backup.snap` | `nomad operator snapshot restore backup.snap` |
| List Raft peers and the Leader | `consul operator raft list-peers` | `nomad operator raft list-peers` |
| List cluster members and versions | `consul members` | `nomad server members` / `nomad node status` |
| Raft details on one node | `consul info` (raft section) | `nomad agent-info` (raft section) |
| Leave the cluster gracefully | `consul leave` | stop the service (servers don't leave the peer set by default) |
| Move workloads off a client | n/a | `nomad node drain -enable -yes <node-id>` |

## 3. Before the upgrade

**Read the upgrade notes for every version you cross.** Both projects publish version-specific notes ([Consul](https://developer.hashicorp.com/consul/docs/upgrading/upgrade-specific), [Nomad](https://developer.hashicorp.com/nomad/docs/upgrade/upgrade-specific)). They call out changed defaults, removed options, and versions you must stop at on the way. Upgrading one minor version per hop (1.7 → 1.8 → 1.9) is the safest path; if you skip versions, make sure none of the notes in between say otherwise. Upgrade a staging cluster first if you have one.

**Take a snapshot** on any server. The snapshot covers the whole cluster state (Consul's KV, catalog, ACLs and intentions; Nomad's jobs, allocations, ACLs and variables):

```bash
consul snapshot save consul-$(date +%Y%m%d%H%M).snap
nomad operator snapshot save nomad-$(date +%Y%m%d%H%M).snap
```

Copy the file off the cluster. A snapshot sitting on the server you are about to upgrade won't help much if that disk is the problem.

**Check that the cluster is healthy and agrees on a Leader:**

```bash
# Consul
consul members
consul operator raft list-peers
consul operator autopilot state    # Consul 1.10+: per-server health

# Nomad
nomad server members
nomad operator raft list-peers
```

Every server should be alive, exactly one should be the Leader, and all should be voters. Note which server is the Leader: you'll upgrade it last.

**Stage the new binary** on every server (or the new package in your repository) before you start, so each node is down only for the restart, not for a download.

## 4. Upgrade the servers, one at a time

Run this on each **Follower** in turn, then on the Leader.

### Consul

```bash
# 1. Leave the cluster gracefully. The server is removed from the Raft peer set,
#    so quorum is recalculated instead of waiting on a dead peer.
consul leave

# 2. Replace the binary (or upgrade the package)
sudo install -m 0755 /tmp/consul /usr/local/bin/consul
consul version

# 3. Start it again. retry_join brings it back into the cluster.
sudo systemctl start consul
```

### Nomad

```bash
# 1. Stop the agent. Nomad servers keep their place in the peer set by default
#    (leave_on_terminate = false), so the cluster expects them back.
sudo systemctl stop nomad

# 2. Replace the binary
sudo install -m 0755 /tmp/nomad /usr/local/bin/nomad
nomad version

# 3. Start it again
sudo systemctl start nomad
```

If the server is also running as a Nomad client, drain it first (`nomad node drain -enable -yes <node-id>`) so its allocations move elsewhere, and disable the drain after the upgrade.

### Wait until it has caught up

Before moving to the next server, check that the upgraded one is back as a voter and has caught up with the Leader:

```bash
# Consul: Healthy should be true for every server
consul operator raft list-peers
consul operator autopilot state
consul info | grep -E 'commit_index|last_log_index'   # compare with the Leader

# Nomad
nomad server members
nomad operator raft list-peers
nomad agent-info | grep -E 'commit_index|last_log_index'
```

`commit_index` and `last_log_index` on the upgraded node should be close to the Leader's and keep climbing with it. Also read the agent's log since the restart (`journalctl -u consul` or `journalctl -u nomad`) for errors.

### The Leader last

Once every Follower runs the new version, upgrade the Leader the same way. When it leaves or stops, the remaining servers, all already upgraded, elect a new Leader among themselves. This short election is expected; clients retry automatically. Expect a few seconds of failed writes during the election and plan the window around it.

## 5. Then the clients

Upgrade clients only after **all** servers are done. Both tools support servers that are newer than their clients, not the other way round.

- **Consul clients**: restart them one at a time with the new binary. Services registered on a client go briefly unhealthy during the restart, so stagger clients that host instances of the same service.
- **Nomad clients**: drain first so allocations move to other nodes, then upgrade and re-enable scheduling:

  ```bash
  nomad node drain -enable -deadline 30m -yes <node-id>
  # replace the binary, restart nomad
  nomad node drain -disable -yes <node-id>   # also makes the node eligible again
  ```

  Drain at most as many clients at once as your spare capacity can absorb.

## 6. Consul on Kubernetes (Helm)

With the official Helm chart, Consul servers run as a StatefulSet. A plain `helm upgrade` would roll every server pod on its own schedule. `server.updatePartition` puts you in control: pods with an ordinal **below** the partition stay on the old version.

1. Set `server.updatePartition` to the number of server replicas (for example `3`) and change the image to the new version in `values.yaml`, then run `helm upgrade`. Nothing restarts yet.
2. Lower the partition by one (`3` → `2`) and `helm upgrade` again. Only the pod with the highest ordinal restarts on the new version.
3. Check its health with `consul operator raft list-peers` (run inside a server pod), then keep lowering the partition (`2` → `1` → `0`), checking after each step.

The client DaemonSet and the other components roll after the servers are done.

## 7. Verify the result

```bash
# Consul
consul members                      # every node on the new version
consul operator raft list-peers     # one Leader, all voters
consul operator autopilot state     # all servers healthy

# Nomad
nomad server members
nomad operator raft list-peers
nomad node status                   # clients ready and eligible
nomad status                        # jobs running as before
```

Then check your own traffic: service discovery answers, KV reads and writes, Nomad deployments and evaluations going through. Keep an eye on the logs for the first few hours.

## 8. Rolling back

How you roll back depends on how far you got:

- **Only some servers upgraded, no problem with the data**: you can usually put the old binary back on those servers one at a time, using the same procedure as the upgrade. Check the upgrade notes first: if the new version changed the on-disk or Raft log format, an older binary may not be able to read the data written since.
- **The state itself is bad, or the old version can't read it**: stop the cluster, bring it back on the old version, and restore the snapshot you took before the upgrade (`consul snapshot restore` / `nomad operator snapshot restore`). Anything written after the snapshot is lost, which is another reason to take it immediately before you start.

A rollback is far easier if you never let the cluster run with more than one server down, which is what the one-at-a-time rule gives you.

## 9. Common issues

**No Leader after an upgrade**

Usually quorum was lost: more than one server was down at the same time, or a server came back but can't reach its peers. Check `list-peers` on each server, firewall rules for the Raft/Serf ports, and whether the servers agree on the Raft protocol version (`consul operator raft list-peers` shows a RaftProtocol column; for Nomad use `nomad agent-info`). If quorum is permanently lost (servers gone for good), both tools have an outage-recovery procedure based on a `peers.json` file. Follow the official guide rather than improvising.

**An upgraded server never catches up**

Its `commit_index` stays behind the Leader's. Check disk space and the permissions of `data_dir` (a binary installed by a different user or package can leave files the agent can't write), and network latency to the Leader. Large clusters can take a while to install a snapshot from the Leader on restart. Give it time before you intervene.

**Nomad evaluations pile up after the upgrade**

Check `nomad operator scheduler get-config` to confirm the scheduler configuration hasn't changed, and look for blocked evaluations with `nomad eval list`. Version-specific notes sometimes change scheduler or ACL defaults.

**Consul clients flap after the server upgrade**

Make sure the clients are within the supported version range of the servers and that the gossip encryption key and TLS settings are unchanged. Servers newer than clients is fine; clients newer than servers is not.

## References

- [Consul: Upgrading Consul](https://developer.hashicorp.com/consul/docs/upgrading)
- [Consul: Upgrade-specific notes](https://developer.hashicorp.com/consul/docs/upgrading/upgrade-specific)
- [Nomad: Upgrading](https://developer.hashicorp.com/nomad/docs/upgrade)
- [Nomad: Upgrade-specific notes](https://developer.hashicorp.com/nomad/docs/upgrade/upgrade-specific)
- [Raft consensus, as used by Consul](https://developer.hashicorp.com/consul/docs/architecture/consensus)
