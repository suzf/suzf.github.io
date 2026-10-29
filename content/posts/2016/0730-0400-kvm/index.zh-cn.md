---
title: "KVM 磁盘管理"
slug: "kvm-磁盘管理"
date: 2016-07-30T04:00:38+08:00
author: "Jeffrey Su"
description: "获取磁盘信息 # qemu-img info /opt/data/kvm/images/hello_kvm.img image: /opt/data/kvm/images/hello_kvm.img file format: qcow2 v…"
categories: ["技能矩阵"]
tags: ["KVM", "linux"]
---

获取磁盘信息
```text
# qemu-img  info /opt/data/kvm/images/hello_kvm.img
image: /opt/data/kvm/images/hello_kvm.img
file format: qcow2
virtual size: 10G (10737418240 bytes)
disk size: 1.1G
cluster_size: 65536
Format specific information:
    compat: 1.1
    lazy refcounts: true
```
创建磁盘镜像文件
```text
# qemu-img create -f qcow2 ubuntu.img 20G
```
磁盘扩容
```text
# qemu-img resize /opt/data/kvm/images/hello_kvm.img  +5G
Image resized.
# qemu-img  info /opt/data/kvm/images/hello_kvm.img
image: /opt/data/kvm/images/hello_kvm.img
file format: qcow2
virtual size: 15G (16106127360 bytes)
disk size: 1.1G
cluster_size: 65536
Format specific information:
    compat: 1.1
    lazy refcounts: true

# virsh destroy hello_kvm
# virsh start   hello_kvm
# virsh console hello_kvm

# fdisk  /dev/vda
Welcome to fdisk (util-linux 2.23.2).

Changes will remain in memory only, until you decide to write them.
Be careful before using the write command.

Command (m for help): p

Disk /dev/vda: 16.1 GB, 16106127360 bytes, 31457280 sectors
Units = sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disk label type: dos
Disk identifier: 0x000dd1eb

   Device Boot      Start         End      Blocks   Id  System
/dev/vda1   *        2048     1026047      512000   83  Linux
/dev/vda2         1026048    20971519     9972736   8e  Linux LVM

Command (m for help): n
Partition type:
   p   primary (2 primary, 0 extended, 2 free)
   e   extended
Select (default p): p
Partition number (3,4, default 3):
First sector (20971520-31457279, default 20971520):
Using default value 20971520
Last sector, +sectors or +size{K,M,G} (20971520-31457279, default 31457279):
Using default value 31457279
Partition 3 of type Linux and of size 5 GiB is set

Command (m for help): p

Disk /dev/vda: 16.1 GB, 16106127360 bytes, 31457280 sectors
Units = sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disk label type: dos
Disk identifier: 0x000dd1eb

   Device Boot      Start         End      Blocks   Id  System
/dev/vda1   *        2048     1026047      512000   83  Linux
/dev/vda2         1026048    20971519     9972736   8e  Linux LVM
/dev/vda3        20971520    31457279     5242880   83  Linux

Command (m for help): w
The partition table has been altered!

Calling ioctl() to re-read partition table.

WARNING: Re-reading the partition table failed with error 16: Device or resource busy.
The kernel still uses the old table. The new table will be used at
the next reboot or after you run partprobe(8) or kpartx(8)
Syncing disks.
```
分区生效
```text
partprobe
```
查看分区
```text
# df -Th --total
Filesystem              Type      Size  Used Avail Use% Mounted on
/dev/mapper/centos-root xfs       8.5G  788M  7.7G  10% /
devtmpfs                devtmpfs  236M     0  236M   0% /dev
tmpfs                   tmpfs     245M     0  245M   0% /dev/shm
tmpfs                   tmpfs     245M  4.4M  241M   2% /run
tmpfs                   tmpfs     245M     0  245M   0% /sys/fs/cgroup
/dev/vda1               xfs       497M  120M  378M  25% /boot
total                   -         9.9G  912M  9.1G   9% -
```
创建物理卷
```text
# pvcreate /dev/vda3
  Physical volume "/dev/vda3" successfully created

# vgs
  VG     #PV #LV #SN Attr   VSize VFree
  centos   1   2   0 wz--n- 9.51g 40.00m
```
把物理卷分区加进卷组
```text
# vgextend centos /dev/vda3
  Volume group "centos" successfully extended

# vgs
  VG     #PV #LV #SN Attr   VSize  VFree
  centos   2   2   0 wz--n- 14.50g 5.04g

# lvextend -L +2G /dev/mapper/centos-root
  Size of logical volume centos/root changed from 8.47 GiB (2168 extents) to 10.47 GiB (2680 extents).
  Logical volume root successfully resized

XFS
# xfs_growfs /dev/mapper/centos-root
meta-data=/dev/mapper/centos-root isize=256    agcount=4, agsize=555008 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=0        finobt=0
data     =                       bsize=4096   blocks=2220032, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0 ftype=0
log      =internal               bsize=4096   blocks=2560, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
data blocks changed from 2220032 to 2744320

EXT
resize2fs /dev/mapper/centos-root
```
添加虚拟磁盘
```text
# mkdir /opt/data/kvm/disk
# qemu-img create -f qcow2 /opt/data/kvm/disk/hello_kvm.qcow2 5G

# virsh destroy hello_kvm
# virsh edit hello_kvm
```
添加新的磁盘
```text
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/opt/data/kvm/disk/hello_kvm.qcow2'/>
      <target dev='vdb' bus='virtio'/>
    </disk>

# virsh start hello_kvm
[root@hello-kvm ~]# fdisk -l /dev/vdb

Disk /dev/vdb: 5368 MB, 5368709120 bytes, 10485760 sectors
Units = sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes

# mkfs [-t <type>] /dev/vdb
# vim /etc/fstab
# mount -a
```
