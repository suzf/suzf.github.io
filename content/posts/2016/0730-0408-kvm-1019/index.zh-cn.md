---
title: "KVM 在线迁移"
slug: "kvm-在线迁移"
date: 2016-07-30T04:08:50+08:00
author: "Jeffrey Su"
description: "在线迁移（Online Migration）也叫动态迁移（Live Migration）。就是在保证虚拟机上服务正常运行的同时，将一个虚拟机系统从一个物理主机移动到另一个物理主机的过程。该过程不会对最终用户造成明显的影响，从而使得管理员能够…"
categories: ["技能矩阵"]
tags: ["KVM", "linux"]
---

在线迁移（Online Migration）也叫动态迁移（Live Migration）。就是在保证虚拟机上服务正常运行的同时，将一个虚拟机系统从一个物理主机移动到另一个物理主机的过程。该过程不会对最终用户造成明显的影响，从而使得管理员能够在不影响用户正常使用的情况下，对物理服务器进行离线维修或者升级。与静态迁移不同的是，为了保证迁移过程中虚拟机服务的可用，迁移过程仅有非常短暂的停机时间。迁移的前面阶段，服务在源主机的虚拟机上运行，当迁移进行到一定阶段，目的主机已经具备了运行虚拟机系统的必须资源，经过一个非常短暂的切换，源主机将控制权转移到目的主机，虚拟机系统在目的主机上继续运行。对于虚拟机服务本身而言，由于切换的时间非常短暂，用户感觉不到服务的中断，因而迁移过程对用户是透明的。动态迁移适用于对虚拟机服务可用性要求很高的场合。

### 环境介绍

```text
172.16.5.10   lab.suzf.net
172.16.5.20   lab2.suzf.net

lab.suzf.net ----> lab2.suzf.net
```

```text
# tree /opt/data/kvm/
/opt/data/kvm/
├── disk
│   └── hello_kvm.qcow2
├── images
│   └── hello_kvm.img
└── iso
└── CentOS-7-x86_64-Minimal-1503-01.iso

3 directories, 3 files
```

NFS 挂载目录 /opt/data/kvm

### 1. 迁移需求

确保待迁移主机使用一下协议之一共享存储：

- Fibre Channel-based LUNs
- iSCSI
- FCoE
- NFS
- GFS2
- SCSI RDMA protocols (SCSI RCP)

### 2. 确保 libvirtd 服务已经启用

### 3. 配置共享存储

#### 3.1 配置 nfs

```text
echo "/opt/data/kvm 172.16.5.0/24(rw,no_root_squash,sync)" >> /etc/exports
```

重启服务

```text
systemctl restart nfs-server.service
```

```text
[root@lab.suzf.net ~]# exportfs -av
exporting 172.16.5.0/24:/opt/data/kvm
```

#### 3.2 挂在到目的节点

```text
[root@lab2 ~]# showmount  -e lab.suzf.net
Export list for lab.suzf.net:
/opt/data/kvm 172.16.5.0/24
```

```text
[root@lab2 ~]# mount -t nfs4 lab.suzf.net:/opt/data/kvm /opt/data/kvm
[root@lab2 ~]# df -Th | grep nfs
lab.suzf.net:/opt/data/kvm nfs4       50G  3.2G   47G   7% /opt/data/kvm
```

### 4. 在线迁移

#### 4.1 确保虚拟机为正在运行状态

```text
[root@lab ~]# virsh  list --all
Id    Name                           State
----------------------------------------------------
2     hello_kvm                      running
```

#### 4.2 开始迁移

```text
[root@lab ~]# virsh migrate --live --verbose hello_kvm qemu+ssh://lab2.suzf.net/system
root@lab2.suzf.net's password:

[root@lab ~]#
```

#### 4.3 wait ~

#### 4.4 验证

```text
[root@lab2 ~]# virsh list --all
Id    Name                           State
----------------------------------------------------
2     hello_kvm                      running
```

虽然 hello\_kvm 虚拟机已经在lab2节点上启动了，但是虚拟主机上还没有配置文件。
所以需要创建配置文件并定义虚拟机。

```text
[root@lab2 ~]# find /etc/ -name "hello_kvm*"
[root@lab2 ~]#
```

创建配置文件

```text
[root@lab2 ~]# virsh dumpxml hello_kvm > /etc/libvirt/qemu/hello_kvm.xml
[root@lab2 ~]# virsh define /etc/libvirt/qemu/hello_kvm.xml
Domain hello_kvm defined from /etc/libvirt/qemu/hello_kvm.xml
```

到此，kvm虚拟机动态迁移成功。

https://www.chenyudong.com/archives/virsh-kvm-live-migration-with-libvirt.html
