---
title: "KVM console 配置"
slug: "kvm-虚拟机-console-配置"
date: 2016-07-30T04:00:03+08:00
author: "Jeffrey Su"
description: "*** All os system is CentOS7 *** 通过 vnc 等软件 控制虚拟机及难免显得有些麻烦。 使用 virsh console 来进行登录来管理无疑是个不错的选择。"
categories: ["技能矩阵"]
tags: ["KVM", "linux"]
---

\*\*\* All os system is CentOS7 \*\*\* 通过 vnc 等软件 控制虚拟机及难免显得有些麻烦。 使用 virsh console 来进行登录来管理无疑是个不错的选择。

<!--more-->

**KVM HOST** 虚拟机XML文件 默认已经支持 无需修改， 如果没有请手动添加

```text
    [root@lab.suzf.net ~]# grep -A 2 -n  pty /etc/libvirt/qemu/hello_kvm.xml
    88:    <serial type='pty'>
    89-      <target port='0'/>
    90-    </serial>
    91:    <console type='pty'>
    92-      <target type='serial' port='0'/>
    93-    </console>
```

**Guest virtual machine** 在 /etc/securetty 文件中添加登录控制台ttyS0 [ 默认已经添加 ]

```text
 [root@hello-kvm ~]# grep ttyS0 /etc/securetty || echo "ttyS0" >> /etc/securetty
```

添加 console=ttyS0 到 grub 配置文件的 kernel 同行

```text
 [root@hello-kvm ~]# grep ttyS0 /etc/grub2.cfg
    linux16 /vmlinuz-3.10.0-229.el7.x86_64 root=/dev/mapper/centos-root ro rd.lvm.lv=centos/root rd.lvm.lv=centos/swap crashkernel=auto rhgb quiet LANG=en_US.UTF-8 console=ttyS0
```

如果是 grub2 系统，请修改/etc/default/grub文件，

```text
 [root@hello-kvm ~]# echo "GRUB_TERMINAL=\"serial console\"
 GRUB_SERIAL_COMMAND=\"serial --speed=115200\"" >> /etc/default/grub
```

如果不是 grub2 系统，请添加 getty or minigetty or agetty 到 /etc/inittab [ 未测 ]

```text
  ehco "S0:12345:respawn:/sbin/agetty ttyS0 115200" >> /etc/inittab
```

重启机器

```text
  [root@hello-kvm ~]# reboot
```

测试 登录到指定的虚拟机

```text
[root@lab.suzf.net ~]# virsh console hello_kvm
Connected to domain hello_kvm
Escape character is ^]    # 按回车键进入

[root@hello-kvm ~]#
[root@hello-kvm ~]# cat /etc/centos-release
CentOS Linux release 7.1.1503 (Core)

  按 ctrl + ] 退出
```

相关连接

http://blog.csdn.net/dobell/article/details/14442457

http://www.linuser.com/thread-1362-1-1.html
