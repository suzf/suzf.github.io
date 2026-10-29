---
title: "KVM 虚拟化实战：从安装到在线迁移"
slug: "kvm virtualization guide"
date: 2016-07-30T03:08:19+08:00
author: "Jeffrey Su"
description: "一篇讲完 KVM 日常运维：检查硬件支持、安装 libvirt、配置 NAT 与网桥网络、用 virt-install 创建虚拟机、配置 virsh console、virsh 常用命令、qemu-img 磁盘扩容与挂载新盘，以及基于共享存储的在线迁移。"
categories: ["技能矩阵"]
tags: ["KVM", "linux"]
toc: true
---

KVM（Kernel-based Virtual Machine）是 Linux 内核自带的虚拟化模块，配合 QEMU 和 libvirt，就能在一台物理机上跑多台互相隔离的虚拟机。本文把一台宿主机从零用起来的完整流程串在一起：检查硬件、安装、网络、创建虚拟机、串口控制台、日常管理、磁盘扩容，最后把一台正在运行的虚拟机在线迁移到另一台宿主机上。

<!--more-->

文中的输出都来自 2016 年的实验环境，宿主机和客户机都是 CentOS 7：

| 角色 | 主机名 | IP |
|---|---|---|
| 宿主机 A | lab.suzf.net | 172.16.5.10 |
| 宿主机 B（迁移目标） | lab2.suzf.net | 172.16.5.20 |
| 虚拟机 | hello_kvm | 由网桥分配 |

虚拟机相关的文件统一放在 `/opt/data/kvm/` 下，在线迁移时这个目录通过 NFS 在两台宿主机间共享：

```text
/opt/data/kvm/
├── disk      # 额外挂载的数据盘
├── images    # 系统盘镜像
└── iso       # 安装光盘
```

命令在 Rocky / Alma / RHEL 8、9 上基本通用，差异会在对应小节单独说明。

## 1. 准备宿主机

### 1.1 检查 CPU 是否支持硬件虚拟化

KVM 依赖 CPU 的硬件虚拟化扩展：Intel 叫 VT-x（标志 `vmx`），AMD 叫 AMD-V（标志 `svm`）。

```text
# grep -cE 'vmx|svm' /proc/cpuinfo
```

输出的是支持虚拟化的逻辑 CPU 数，为 0 说明 CPU 不支持，或者 BIOS 里没有打开虚拟化选项（常见名字是 Intel Virtualization Technology / SVM Mode）。如果宿主机本身就是一台云主机，还需要云厂商开启嵌套虚拟化。

### 1.2 安装 KVM 和 libvirt

```text
# yum install -y qemu-kvm libvirt virt-install bridge-utils
# systemctl enable libvirtd
# systemctl start libvirtd
```

确认内核模块已经加载，应能看到 `kvm` 和 `kvm_intel`（AMD 上是 `kvm_amd`）：

```text
# lsmod | grep kvm
```

需要图形界面管理的话再装 `virt-manager`。

## 2. 网络：NAT 还是网桥

KVM 客户机有两种常用的联网方式：

| | NAT（默认） | 网桥（Bridge） |
|---|---|---|
| 原理 | libvirt 建一个 `virbr0` 虚拟交换机，客户机经宿主机做地址转换出网 | 把物理网卡接到网桥 `br0` 上，客户机像一台独立主机一样接入物理网络 |
| 客户机 IP | 192.168.122.0/24 私网地址 | 与宿主机同网段的独立 IP |
| 外部能否访问客户机 | 不能（除非做端口转发） | 能 |
| 配置 | 安装后即可用 | 需要手动配置 |

只是自己做实验、客户机只需要出网，用 NAT 就够了。要对外提供服务，或者要做在线迁移（迁移后 IP 不能变），用网桥。

### 2.1 配置网桥（CentOS 7 network-scripts）

**第一步**：新建网桥设备 `/etc/sysconfig/network-scripts/ifcfg-br0`，IP 配置在网桥上：

```text
DEVICE="br0"
TYPE="Bridge"
BOOTPROTO=static
IPADDR=10.1.83.205
PREFIX=22
GATEWAY=10.1.80.254
DNS1=59.108.119.3
IPV4_FAILURE_FATAL=yes
IPV6INIT=no
NAME=br0
ONBOOT=yes
DELAY=0
```

**第二步**：修改物理网卡 `/etc/sysconfig/network-scripts/ifcfg-eth0`，去掉它的 IP 配置，挂到 `br0` 上：

```text
DEVICE="eth0"
TYPE=Ethernet
BRIDGE="br0"
BOOTPROTO=none
DEFROUTE=yes
IPV4_FAILURE_FATAL=yes
IPV6INIT=no
NAME=system-eth0
ONBOOT=yes
```

当时的 NetworkManager 不支持桥接，Red Hat 文档要求停用 NetworkManager，或者在网卡配置里写 `NM_CONTROLLED="no"`。实测写成 `yes` 也能正常通信，但为了稳妥建议按文档来。

**第三步**：重启网络并确认物理网卡和虚拟机网卡（`vnetN`）都挂在 `br0` 上：

```text
# systemctl restart network
# brctl show
bridge name     bridge id               STP enabled     interfaces
br0             8000.003048c68ab0       no              eth0
                                                        vnet0
                                                        vnet1
```

建议在控制台（IPMI / 物理终端）上操作这一步，配置写错时 SSH 会直接断开。

### 2.2 RHEL 8 及以后：用 nmcli

新版本已经移除了 network-scripts，网桥改用 NetworkManager 配置，效果和上面一样：

```text
# nmcli con add type bridge ifname br0 con-name br0 \
    ipv4.method manual ipv4.addresses 10.1.83.205/22 \
    ipv4.gateway 10.1.80.254 ipv4.dns 59.108.119.3
# nmcli con add type bridge-slave ifname eth0 master br0
# nmcli con up br0
```

### 2.3 网桥的注意事项

- IP 配置在网桥上，被桥接的物理网卡不需要配置 IP；
- 网桥和物理网卡都必须处于 running 状态；
- 创建虚拟机时网络要选 `bridge=br0`；
- 客户机的 IP 要和宿主机在同一网段。

## 3. 创建虚拟机

创建虚拟机有两种方式：图形化的 virt-manager 和命令行的 virt-install。

### 3.1 virt-manager

virt-manager 是基于 libvirt 的图形化管理工具，适合刚上手时熟悉各项配置。首次使用需要：

1. 连接 localhost（`qemu:///system`）；
2. 配置虚拟网络：默认是 NAT 方式的 `default`，也可以选择上一节建好的网桥；
3. 创建或添加存储池，可以是逻辑卷，也可以是镜像文件目录。

之后按向导一路往下即可，不再赘述。

### 3.2 virt-install

virt-install 可以写进脚本，配合 Kickstart 文件还能做到无人值守批量装机。需要以 root 身份执行，完整参数见 `virt-install --help`。

**从本地 ISO 安装**，用 VNC 连上去完成安装界面：

```text
virt-install \
--connect qemu:///system \
--name kvm_node_name \
--ram 512 \
--vcpus 1 \
--hvm \
--disk path=/opt/data/kvm/images/kvm_node_name.img,size=10 \
--os-type linux \
--os-variant rhel7 \
--network bridge=br0 \
--noautoconsole \
--graphics vnc,listen=0.0.0.0 \
--location=/opt/data/kvm/iso/CentOS-7-x86_64-Minimal-1503-01.iso
```

`--graphics vnc,listen=0.0.0.0` 会让 VNC 监听所有网卡，只适合内网实验环境；生产环境请监听 127.0.0.1，再通过 SSH 隧道连接。用 `virsh vncdisplay kvm_node_name` 可以查到 VNC 端口。

**从网络源安装**，不要图形界面，直接在串口控制台里完成安装：

```text
virt-install \
--name smile \
--ram 512 \
--vcpus 1 \
--disk path=/opt/data/kvm/images/smile.img,size=10 \
--os-type linux \
--os-variant rhel7 \
--network bridge=br0 \
--graphics none \
--console pty,target_type=serial \
--extra-args 'console=ttyS0,115200n8 serial' \
--location=http://mirrors.163.com/centos/6.7/os/x86_64/
```

**无人值守安装**：用 `--extra-args` 把 Kickstart 文件的位置传给安装程序：

```text
--extra-args="ks=ftp://lab.suzf.net/ks/myks.cfg"
# 或者
--extra-args "ks=file:/myks.cfg"
```

**同时指定串口控制台**：

```text
--console pty,target_type=serial \
--extra-args='console=tty0 console=ttyS0,115200n8 serial'
```

可用的 `--os-variant` 取值可以用 `osinfo-query os` 查看。新版 virt-install 已经弃用 `--os-type`，改用 `--osinfo`（如 `--osinfo rhel9.0`）。

## 4. 配置 virsh console

每次都用 VNC 连虚拟机很麻烦。配好串口控制台后，在宿主机上一条 `virsh console` 就能登录客户机，网络配置出错、SSH 连不上时尤其有用。

**宿主机**：虚拟机的 XML 里需要有 `pty` 类型的串口和控制台，virt-install 创建的虚拟机默认已经有了，没有的话用 `virsh edit` 手动添加：

```text
[root@lab.suzf.net ~]# grep -A 2 -n pty /etc/libvirt/qemu/hello_kvm.xml
88:    <serial type='pty'>
89-      <target port='0'/>
90-    </serial>
91:    <console type='pty'>
92-      <target type='serial' port='0'/>
93-    </console>
```

**客户机**：

1. 允许 root 从 `ttyS0` 登录（CentOS 7 默认已经允许）：

   ```text
   [root@hello-kvm ~]# grep ttyS0 /etc/securetty || echo "ttyS0" >> /etc/securetty
   ```

2. 让内核把控制台输出到串口：在内核启动参数里加上 `console=ttyS0`。grub2 系统修改 `/etc/default/grub`，在 `GRUB_CMDLINE_LINUX` 末尾追加 `console=ttyS0,115200n8`，并让 grub 菜单也走串口：

   ```text
   [root@hello-kvm ~]# echo 'GRUB_TERMINAL="serial console"
   GRUB_SERIAL_COMMAND="serial --speed=115200"' >> /etc/default/grub
   [root@hello-kvm ~]# grub2-mkconfig -o /boot/grub2/grub.cfg
   ```

   生成后可以确认 `console=ttyS0` 已经出现在 kernel 那一行：

   ```text
   [root@hello-kvm ~]# grep ttyS0 /etc/grub2.cfg
   linux16 /vmlinuz-3.10.0-229.el7.x86_64 root=/dev/mapper/centos-root ro rd.lvm.lv=centos/root rd.lvm.lv=centos/swap crashkernel=auto rhgb quiet LANG=en_US.UTF-8 console=ttyS0
   ```

   使用 SysV init 的老系统（如 CentOS 5）还需要在 `/etc/inittab` 里为串口启动一个 getty（未实测）：

   ```text
   echo "S0:12345:respawn:/sbin/agetty ttyS0 115200" >> /etc/inittab
   ```

3. 重启客户机。

**测试**：

```text
[root@lab.suzf.net ~]# virsh console hello_kvm
Connected to domain hello_kvm
Escape character is ^]

[root@hello-kvm ~]# cat /etc/centos-release
CentOS Linux release 7.1.1503 (Core)
```

连上后如果没有提示符，按一下回车。退出控制台按 `Ctrl + ]`。

## 5. 日常管理：virsh 常用命令

下面的 `<vm>` 可以是虚拟机名称、ID 或 UUID。

**查看信息**

| 命令 | 作用 |
|---|---|
| `virsh list --all` | 列出所有虚拟机（含已关机的） |
| `virsh dominfo <vm>` | 虚拟机的 CPU、内存、状态等信息 |
| `virsh domid <vm>` / `virsh domname <vm>` / `virsh domuuid <vm>` | 名称、ID、UUID 互查 |
| `virsh vncdisplay <vm>` | 查看 VNC 端口 |
| `virsh domblklist <vm>` | 列出虚拟机的磁盘 |
| `virsh domiflist <vm>` | 列出虚拟机的网卡 |

**开关机**

| 命令 | 作用 |
|---|---|
| `virsh start <vm>` | 启动 |
| `virsh shutdown <vm>` | 正常关机（向客户机发送 ACPI 关机信号） |
| `virsh reboot <vm>` | 正常重启 |
| `virsh destroy <vm>` | 强制断电，相当于拔电源，可能丢数据 |
| `virsh suspend <vm>` / `virsh resume <vm>` | 暂停 / 恢复（内存保留，不释放资源） |
| `virsh save <vm> <file>` / `virsh restore <file>` | 把运行状态保存到文件 / 从文件恢复 |
| `virsh autostart <vm>` / `virsh autostart --disable <vm>` | 开启 / 取消随宿主机自动启动 |

**修改配置**

| 命令 | 作用 |
|---|---|
| `virsh edit <vm>` | 用编辑器修改 XML，保存时自动校验并生效（下次启动） |
| `virsh dumpxml <vm> > vm.xml` | 导出 XML |
| `virsh define /path/to/vm.xml` | 用 XML 定义（注册）虚拟机 |

不要直接改 `/etc/libvirt/qemu/` 下的 XML 文件：libvirtd 不会读取手工修改，下次保存时还会覆盖掉。要么用 `virsh edit`，要么改完副本后用 `virsh define` 重新注册。

**彻底删除一台虚拟机**：

```text
# virsh destroy  <vm>
# virsh undefine <vm>
# rm -f /var/lib/libvirt/images/<vm>.img
```

`undefine` 只删除定义，不会删除磁盘镜像。新版 libvirt 可以用 `virsh undefine <vm> --remove-all-storage` 一并删除。

## 6. 磁盘管理

### 6.1 查看和创建磁盘镜像

`qemu-img info` 能看出镜像格式、虚拟大小和实际占用：

```text
# qemu-img info /opt/data/kvm/images/hello_kvm.img
image: /opt/data/kvm/images/hello_kvm.img
file format: qcow2
virtual size: 10G (10737418240 bytes)
disk size: 1.1G
cluster_size: 65536
Format specific information:
    compat: 1.1
    lazy refcounts: true
```

qcow2 是按需分配的：虚拟大小 10G，实际只占 1.1G。新建一块 20G 的镜像：

```text
# qemu-img create -f qcow2 ubuntu.img 20G
```

### 6.2 系统盘扩容（qcow2 + LVM + XFS）

把 hello_kvm 的系统盘从 10G 扩到 15G，并把多出来的空间加到根分区。整个过程分三层：先扩镜像，再在客户机里分区，最后扩 LVM 和文件系统。

**第一步：扩大镜像**（下面的做法需要虚拟机关机）：

```text
# virsh shutdown hello_kvm
# qemu-img resize /opt/data/kvm/images/hello_kvm.img +5G
Image resized.
# qemu-img info /opt/data/kvm/images/hello_kvm.img | grep virtual
virtual size: 15G (16106127360 bytes)
# virsh start hello_kvm
# virsh console hello_kvm
```

扩容前最好先备份镜像。不想停机的话，可以在虚拟机运行时用 `virsh blockresize hello_kvm vda 15G`，客户机内核会立即看到新容量。

**第二步：在客户机里把新空间建成分区**。规范的做法是在写入前用 `t` 把分区类型改成 `8e`（Linux LVM），不过保持默认的 83 也不影响后面的 `pvcreate`，下面的实验就是这样：

```text
[root@hello-kvm ~]# fdisk /dev/vda
Command (m for help): n
Partition type:
   p   primary (2 primary, 0 extended, 2 free)
   e   extended
Select (default p): p
Partition number (3,4, default 3):
First sector (20971520-31457279, default 20971520):
Last sector, +sectors or +size{K,M,G} (20971520-31457279, default 31457279):
Partition 3 of type Linux and of size 5 GiB is set

Command (m for help): p
   Device Boot      Start         End      Blocks   Id  System
/dev/vda1   *        2048     1026047      512000   83  Linux
/dev/vda2         1026048    20971519     9972736   8e  Linux LVM
/dev/vda3        20971520    31457279     5242880   83  Linux

Command (m for help): w
WARNING: Re-reading the partition table failed with error 16: Device or resource busy.
The kernel still uses the old table. The new table will be used at
the next reboot or after you run partprobe(8) or kpartx(8)
```

系统盘正在使用，内核没能重新读取分区表，执行 `partprobe` 让新分区生效（不行就重启一次）：

```text
[root@hello-kvm ~]# partprobe
```

**第三步：扩 LVM 和文件系统**。把新分区建成物理卷，加入卷组 `centos`：

```text
[root@hello-kvm ~]# pvcreate /dev/vda3
  Physical volume "/dev/vda3" successfully created
[root@hello-kvm ~]# vgextend centos /dev/vda3
  Volume group "centos" successfully extended
[root@hello-kvm ~]# vgs
  VG     #PV #LV #SN Attr   VSize  VFree
  centos   2   2   0 wz--n- 14.50g 5.04g
```

给根分区所在的逻辑卷加 2G，再扩文件系统。XFS 用 `xfs_growfs`，ext4 用 `resize2fs`，两者都可以在挂载状态下在线扩容：

```text
[root@hello-kvm ~]# lvextend -L +2G /dev/mapper/centos-root
  Size of logical volume centos/root changed from 8.47 GiB (2168 extents) to 10.47 GiB (2680 extents).
  Logical volume root successfully resized
[root@hello-kvm ~]# xfs_growfs /dev/mapper/centos-root
...
data blocks changed from 2220032 to 2744320

# 如果是 ext4：
[root@hello-kvm ~]# resize2fs /dev/mapper/centos-root
```

`lvextend -r` 可以在扩逻辑卷的同时自动扩文件系统，省掉最后一步。XFS 只能扩大不能缩小，分配空间时要留有余地。

### 6.3 添加一块数据盘

先在宿主机上创建镜像：

```text
# mkdir -p /opt/data/kvm/disk
# qemu-img create -f qcow2 /opt/data/kvm/disk/hello_kvm.qcow2 5G
```

然后 `virsh edit hello_kvm`，在 `<devices>` 里加一个 `<disk>`，目标设备名不要和已有磁盘冲突：

```text
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2'/>
  <source file='/opt/data/kvm/disk/hello_kvm.qcow2'/>
  <target dev='vdb' bus='virtio'/>
</disk>
```

关机再启动后新盘生效（`virsh reboot` 不会重新读取 XML）。也可以不停机，直接热插拔并写入配置：

```text
# virsh attach-disk hello_kvm /opt/data/kvm/disk/hello_kvm.qcow2 vdb \
    --driver qemu --subdriver qcow2 --persistent
```

客户机里就能看到 `/dev/vdb` 了，接下来按普通磁盘处理：格式化、写入 `/etc/fstab`、挂载。

```text
[root@hello-kvm ~]# fdisk -l /dev/vdb
Disk /dev/vdb: 5368 MB, 5368709120 bytes, 10485760 sectors

[root@hello-kvm ~]# mkfs.xfs /dev/vdb
[root@hello-kvm ~]# mkdir /data
[root@hello-kvm ~]# echo '/dev/vdb /data xfs defaults 0 0' >> /etc/fstab
[root@hello-kvm ~]# mount -a
```

## 7. 在线迁移

在线迁移（Live Migration）是指虚拟机在运行状态下，从一台宿主机移动到另一台宿主机。迁移过程中内存页被逐轮复制到目标机，只在最后切换的一瞬间短暂停顿，客户机里的服务和网络连接基本不受影响。这样就能在不停业务的前提下，对物理服务器做维修或升级。

下面把 hello_kvm 从 lab.suzf.net 迁移到 lab2.suzf.net。

### 7.1 前提条件

- **共享存储**：两台宿主机必须能以相同路径访问虚拟机磁盘。可用 Fibre Channel LUN、iSCSI、FCoE、NFS、GFS2、SCSI RDMA 等，这里用 NFS。
- 两台宿主机都在运行 libvirtd，源主机能用 SSH 登录目标主机。
- 虚拟机使用网桥网络，两台宿主机上的网桥名称一致（都叫 `br0`）。
- 两台宿主机的 CPU 型号最好一致，至少目标机要支持虚拟机用到的全部 CPU 特性。

### 7.2 配置共享存储

在 lab.suzf.net 上把 `/opt/data/kvm` 通过 NFS 导出：

```text
[root@lab.suzf.net ~]# echo "/opt/data/kvm 172.16.5.0/24(rw,no_root_squash,sync)" >> /etc/exports
[root@lab.suzf.net ~]# systemctl restart nfs-server.service
[root@lab.suzf.net ~]# exportfs -av
exporting 172.16.5.0/24:/opt/data/kvm
```

在 lab2 上挂载到相同的路径：

```text
[root@lab2 ~]# showmount -e lab.suzf.net
Export list for lab.suzf.net:
/opt/data/kvm 172.16.5.0/24

[root@lab2 ~]# mount -t nfs4 lab.suzf.net:/opt/data/kvm /opt/data/kvm
[root@lab2 ~]# df -Th | grep nfs
lab.suzf.net:/opt/data/kvm nfs4       50G  3.2G   47G   7% /opt/data/kvm
```

### 7.3 执行迁移

确认虚拟机正在运行：

```text
[root@lab ~]# virsh list --all
 Id    Name                           State
----------------------------------------------------
 2     hello_kvm                      running
```

开始迁移，`--verbose` 会显示进度：

```text
[root@lab ~]# virsh migrate --live --verbose hello_kvm qemu+ssh://lab2.suzf.net/system
root@lab2.suzf.net's password:

[root@lab ~]#
```

迁移时间取决于内存大小、内存脏页速度和网络带宽。可以在客户机里持续 `ping` 一个地址观察：通常只会丢一两个包。

### 7.4 验证并在目标机上持久化

```text
[root@lab2 ~]# virsh list --all
 Id    Name                           State
----------------------------------------------------
 2     hello_kvm                      running
```

虚拟机已经在 lab2 上运行，但 lab2 上还没有它的配置文件，一旦关机就会“消失”：

```text
[root@lab2 ~]# find /etc/ -name "hello_kvm*"
[root@lab2 ~]#
```

导出 XML 并定义虚拟机：

```text
[root@lab2 ~]# virsh dumpxml hello_kvm > /etc/libvirt/qemu/hello_kvm.xml
[root@lab2 ~]# virsh define /etc/libvirt/qemu/hello_kvm.xml
Domain hello_kvm defined from /etc/libvirt/qemu/hello_kvm.xml
```

更省事的做法是迁移时加上 `--persistent --undefinesource`：在目标机上持久化定义，同时删除源主机上的定义，一步到位：

```text
# virsh migrate --live --persistent --undefinesource --verbose \
    hello_kvm qemu+ssh://lab2.suzf.net/system
```

## 8. 常见问题

**`virsh shutdown` 之后虚拟机没反应**

`shutdown` 和 `reboot` 是向客户机发送 ACPI 电源信号，客户机里必须有程序处理它。CentOS 6 及更早的最小化安装需要装上 acpid：

```text
yum install -y acpid
service acpid start
chkconfig acpid on
```

另一个办法是在客户机里安装 `qemu-guest-agent`，然后用 `virsh shutdown <vm> --mode agent`。实在关不掉只能 `virsh destroy` 强制断电。

**`virsh console` 连上后没有任何输出**

先按回车。还是没有的话，检查客户机的内核参数里有没有 `console=ttyS0`（`cat /proc/cmdline`），以及 XML 里是否有 `pty` 串口，见第 4 节。

**改了 XML 不生效**

`virsh edit` 修改的是持久配置，要等虚拟机下次冷启动才生效。`virsh reboot` 是客户机内部重启，不会重新加载 XML，需要 `shutdown` 再 `start`。

**迁移报错 CPU 不兼容**

目标宿主机的 CPU 缺少虚拟机正在使用的特性。可以给虚拟机指定一个两边都支持的通用 CPU 型号（XML 里的 `<cpu mode='custom'>`），或者把 CPU 型号较新的宿主机作为迁移目标。

## 参考链接

- [Live migration with libvirt — chenyudong.com](https://www.chenyudong.com/archives/virsh-kvm-live-migration-with-libvirt.html)
- [libvirt: virsh 命令参考](https://www.libvirt.org/manpages/virsh.html)
- [virt-install 手册](https://github.com/virt-manager/virt-manager/blob/main/man/virt-install.rst)
