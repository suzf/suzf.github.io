---
title: "Consul 与 Nomad Server 集群滚动升级：全程不丢 Quorum"
slug: "nomad server cluster upgrade"
date: 2026-03-31T22:09:08+08:00
author: "Jeffrey Su"
description: "一套流程升级 Consul 和 Nomad Server：Quorum 计算、升级前快照、先 Follower 后 Leader、先 Server 后 Client、Helm updatePartition、升级后验证、回滚与常见故障。"
categories: ["技能矩阵"]
tags: ["consul", "nomad"]
toc: true
draft: false
---

Consul 和 Nomad 底层用的是同一个 HashiCorp Raft 库，所以 Server 集群的升级套路完全一样：先做快照，一次只换一台 Server，Leader 留到最后，Server 全部升级完再动 Client。顺序一旦搞错，集群就会失去 Quorum、拒绝写入，维护窗口就从“升级”变成了“抢修”。

本文把两者放在一起讲：通用流程、两边不同的命令、在 Kubernetes 上用 Helm 升级 Consul，以及升级后如何验证和回滚。

<!--more-->

## 1. 为什么顺序这么重要：Quorum

Raft 集群只有在多数 Server（即 **Quorum**）在线且互通时，才能提交写入、选出 Leader：

| Server 数 | Quorum | 可容忍故障数 |
|---|---|---|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

滚动升级期间总有一台 Server 处于停机状态。对 3 台的集群来说，这已经用掉了唯一一次可容忍的故障，所以：

- **一次只升级一台**，上一台恢复并追上数据之前，不要动下一台；
- 开始前确认所有 Server 都健康。如果已经有一台有问题，再停一台升级，集群就停摆了；
- **Leader 最后升级**，这样整个过程只发生一次选举，而不是每台 Server 一次。

这也是生产环境用 3 台或 5 台 Server 的原因：5 台的集群即使有一台正在升级，也仍然能再容忍一次故障。

## 2. 命令速查

| 操作 | Consul | Nomad |
|---|---|---|
| 保存快照 | `consul snapshot save backup.snap` | `nomad operator snapshot save backup.snap` |
| 恢复快照 | `consul snapshot restore backup.snap` | `nomad operator snapshot restore backup.snap` |
| 查看 Raft 成员和 Leader | `consul operator raft list-peers` | `nomad operator raft list-peers` |
| 查看集群成员和版本 | `consul members` | `nomad server members` / `nomad node status` |
| 查看单个节点的 Raft 详情 | `consul info`（raft 部分） | `nomad agent-info`（raft 部分） |
| 优雅离开集群 | `consul leave` | 停止服务即可（Server 默认不会退出成员列表） |
| 把负载迁出 Client | 无 | `nomad node drain -enable -yes <node-id>` |

## 3. 升级前准备

**逐个阅读跨过的每个版本的升级说明。** 两个项目都有按版本列出的升级说明（[Consul](https://developer.hashicorp.com/consul/docs/upgrading/upgrade-specific)、[Nomad](https://developer.hashicorp.com/nomad/docs/upgrade/upgrade-specific)），里面会写明默认值的变化、被移除的配置项，以及中途必须停留的版本。最稳妥的做法是每次只升一个次要版本（1.7 → 1.8 → 1.9）；如果要跳版本，先确认中间所有版本的说明里都没有反对。有预发环境的话，先在预发集群上走一遍。

**做快照**，在任意一台 Server 上执行即可。快照包含整个集群的状态（Consul 的 KV、服务目录、ACL、intention；Nomad 的 job、allocation、ACL、变量）：

```bash
consul snapshot save consul-$(date +%Y%m%d%H%M).snap
nomad operator snapshot save nomad-$(date +%Y%m%d%H%M).snap
```

把快照文件拷到集群之外。如果出问题的恰好是那台 Server 的磁盘，放在它上面的快照就派不上用场了。

**确认集群健康、Leader 唯一：**

```bash
# Consul
consul members
consul operator raft list-peers
consul operator autopilot state    # Consul 1.10+：逐台显示健康状态

# Nomad
nomad server members
nomad operator raft list-peers
```

所有 Server 都应是 alive，只有一台是 Leader，并且都是 voter。记下 Leader 是哪一台，它要最后升级。

**提前分发新版本二进制**（或把新包放进软件源），这样每台节点停机的时间只有重启那一下，而不是还要等下载。

## 4. 逐台升级 Server

依次在每台 **Follower** 上执行，最后再升级 Leader。

### Consul

```bash
# 1. 优雅离开集群。该 Server 会被移出 Raft 成员列表，
#    Quorum 会重新计算，而不是一直等一个掉线的成员。
consul leave

# 2. 替换二进制（或升级软件包）
sudo install -m 0755 /tmp/consul /usr/local/bin/consul
consul version

# 3. 重新启动，retry_join 会让它自动重新加入集群
sudo systemctl start consul
```

### Nomad

```bash
# 1. 停止 agent。Nomad Server 默认保留在成员列表中
#    （leave_on_terminate = false），集群会等它回来。
sudo systemctl stop nomad

# 2. 替换二进制
sudo install -m 0755 /tmp/nomad /usr/local/bin/nomad
nomad version

# 3. 重新启动
sudo systemctl start nomad
```

如果这台 Server 同时也是 Nomad Client，先 drain（`nomad node drain -enable -yes <node-id>`）把上面的 allocation 迁走，升级完再取消 drain。

### 等它追上数据

升级下一台之前，确认刚升级的这台已经作为 voter 回到集群，并追上了 Leader：

```bash
# Consul：每台 Server 的 Healthy 都应为 true
consul operator raft list-peers
consul operator autopilot state
consul info | grep -E 'commit_index|last_log_index'   # 与 Leader 对比

# Nomad
nomad server members
nomad operator raft list-peers
nomad agent-info | grep -E 'commit_index|last_log_index'
```

升级后节点的 `commit_index` 和 `last_log_index` 应该和 Leader 接近，并随 Leader 一起增长。同时看一下重启以来的日志（`journalctl -u consul` 或 `journalctl -u nomad`）有没有报错。

### 最后升级 Leader

所有 Follower 都换成新版本后，用同样的步骤升级 Leader。它离开或停止时，其余已经升级好的 Server 会在彼此之间选出新的 Leader。这次短暂的选举是预期行为，客户端会自动重试；选举期间会有几秒钟写入失败，安排维护窗口时要把这一点算进去。

## 5. 然后升级 Client

**所有** Server 升级完成后再升级 Client。两个工具都支持 Server 版本比 Client 新，反过来则不行。

- **Consul Client**：逐台用新二进制重启。重启期间注册在这台 Client 上的服务会短暂不健康，所以承载同一服务实例的 Client 要错开升级。
- **Nomad Client**：先 drain 让 allocation 迁到其他节点，升级后再恢复调度：

  ```bash
  nomad node drain -enable -deadline 30m -yes <node-id>
  # 替换二进制，重启 nomad
  nomad node drain -disable -yes <node-id>   # 同时恢复该节点的可调度状态
  ```

  同时 drain 的 Client 数量不要超过剩余容量能承接的范围。

## 6. Kubernetes 上的 Consul（Helm）

使用官方 Helm chart 时，Consul Server 以 StatefulSet 运行。直接 `helm upgrade` 会按 StatefulSet 自己的节奏重启所有 Server Pod。`server.updatePartition` 能让你掌控节奏：序号**小于**该值的 Pod 保持旧版本。

1. 在 `values.yaml` 里把 `server.updatePartition` 设为 Server 副本数（例如 `3`），同时把镜像改成新版本，执行 `helm upgrade`。此时不会有任何 Pod 重启。
2. 把 partition 减一（`3` → `2`）再 `helm upgrade`，只有序号最大的那个 Pod 会以新版本重启。
3. 在 Server Pod 里执行 `consul operator raft list-peers` 确认健康后，继续逐步减小 partition（`2` → `1` → `0`），每一步都检查一次。

Client DaemonSet 和其他组件会在 Server 全部升级后再滚动。

## 7. 验证升级结果

```bash
# Consul
consul members                      # 所有节点都是新版本
consul operator raft list-peers     # 一个 Leader，全部是 voter
consul operator autopilot state     # 所有 Server 健康

# Nomad
nomad server members
nomad operator raft list-peers
nomad node status                   # Client 为 ready 且 eligible
nomad status                        # job 运行状态与升级前一致
```

然后检查自己的业务：服务发现能否正常解析、KV 读写是否正常、Nomad 的 deployment 和 evaluation 是否顺利完成。升级后的头几个小时多留意日志。

## 8. 回滚

怎么回滚取决于升级进行到了哪一步：

- **只升级了部分 Server，数据没有问题**：通常可以按升级时的流程，逐台把旧版本二进制换回去。但要先查升级说明：如果新版本改变了磁盘或 Raft 日志格式，旧版本可能读不了新版本写入的数据。
- **状态数据本身有问题，或者旧版本读不了**：停掉集群，用旧版本重新拉起，再恢复升级前做的快照（`consul snapshot restore` / `nomad operator snapshot restore`）。快照之后写入的数据会丢失，所以快照要在开始升级前一刻再做。

只要始终坚持“一次只停一台”，集群就不会同时少两台 Server，回滚也会简单得多。

## 9. 常见问题

**升级后选不出 Leader**

通常是 Quorum 丢了：同时有不止一台 Server 停机，或者某台恢复后连不上其他成员。逐台检查 `list-peers`，检查 Raft/Serf 端口的防火墙规则，并确认各 Server 的 Raft 协议版本一致（`consul operator raft list-peers` 有 RaftProtocol 一列；Nomad 用 `nomad agent-info` 查看）。如果 Quorum 永久丢失（Server 再也回不来），两个工具都有基于 `peers.json` 的故障恢复流程，请严格按官方文档操作，不要自己摸索。

**升级后的 Server 一直追不上**

它的 `commit_index` 一直落后于 Leader。检查磁盘空间和 `data_dir` 的权限（换了用户或软件包安装的二进制可能导致 agent 写不了文件），以及到 Leader 的网络延迟。大集群重启后需要从 Leader 安装快照，可能要等一会儿，先别急着干预。

**Nomad 升级后 evaluation 堆积**

用 `nomad operator scheduler get-config` 确认调度器配置没有变化，用 `nomad eval list` 查看被阻塞的 evaluation。有些版本的升级说明会修改调度器或 ACL 的默认值。

**Server 升级后 Consul Client 状态反复跳变**

确认 Client 版本在 Server 支持的范围内，gossip 加密密钥和 TLS 配置没有变化。Server 比 Client 新没问题，Client 比 Server 新则不行。

## 参考链接

- [Consul: Upgrading Consul](https://developer.hashicorp.com/consul/docs/upgrading)
- [Consul: Upgrade-specific notes](https://developer.hashicorp.com/consul/docs/upgrading/upgrade-specific)
- [Nomad: Upgrading](https://developer.hashicorp.com/nomad/docs/upgrade)
- [Nomad: Upgrade-specific notes](https://developer.hashicorp.com/nomad/docs/upgrade/upgrade-specific)
- [Consul 使用的 Raft 共识机制](https://developer.hashicorp.com/consul/docs/architecture/consensus)
