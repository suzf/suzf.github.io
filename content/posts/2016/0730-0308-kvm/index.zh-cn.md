---
title: "KVM 虚拟机安装"
slug: "kvm-虚拟机安装"
date: 2016-07-30T03:08:19+08:00
author: "Jeffrey Su"
description: "两种方式： virt-manager virt-install virt-manager virt-manager 是基于 libvirt 的图像化虚拟机管理软件，请注意不同的发行版上 virt-manager 的版本可能不同，图形界面和操…"
categories: ["技能矩阵"]
tags: ["KVM", "linux"]
---

两种方式：

virt-manager
virt-install

virt-manager
virt-manager 是基于 libvirt 的图像化虚拟机管理软件，请注意不同的发行版上 virt-manager 的版本可能不同，图形界面和操作方法也可能不同。创建KVM虚拟机最简单的方法是通过virt-manager接口。

1. 需要对localhost进行连接配置
2. 对虚拟网络进行配置，默认为nat方式的“default”，可以新添加网桥方式，也可以使用btctl创建
3. 创建或添加存储，可以是逻辑卷，也可以硬盘文件

安装
yum install virt-manager -y

图形操作直接略过, 多点几下就会用了基本上。

virt-install
你可以通过使用 virt-install 命令行来创建客户虚拟机。
virt-install也可以以一种交互的形式  或者使用一部分的脚本来自动化创建虚拟机。
也可以将 virt-install 和 ks 文件结合起来 实现自动部署

查看帮助
# virt-install --help

请注意，你需要以root权限进行的virt-install命令。qemu-img 是一个相关的命令在virt-安装配置存储选项 之前可以使用。
一个重要的选项是--graphics选项，允许一个虚拟机的图形化安装。

举个栗子
本地安装

```
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

通过网络安装 虚拟机

```
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

指定 KS 文件

```
--extra-args="ks=ftp://lab.suzf.net/ks/myks.cfg"
or
--extra-args "ks=file:/myks.cfg"
```

指定 console

```
--console pty,target_type=serial \
--extra-args='console=tty0 console=ttyS0,115200n8 serial'
```
