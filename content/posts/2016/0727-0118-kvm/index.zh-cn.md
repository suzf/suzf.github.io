---
title: "KVM 虚拟机管理"
slug: "kvm-虚拟机管理"
date: 2016-07-27T01:18:50+08:00
author: "Jeffrey Su"
description: "常用 virsh 命令 # virsh help # virsh version 显示所有虚拟机 # virsh list --all 获取 domain ID # virsh domid {domain-name or domain-uu…"
categories: ["技能矩阵"]
tags: ["KVM", "linux"]
---

常用 virsh 命令
# virsh help
# virsh version

显示所有虚拟机
# virsh list --all

获取 domain ID
# virsh domid {domain-name or domain-uuid}

获取 domain name
# virsh domname {domain-id or domain-uuid}

获取 UUID
# virsh domuuid {domain-id or domain-name}

获取 虚拟机信息
# virsh dominfo {domain-id, domain-name or domain-uuid}

登录到指定的虚拟机
# virsh console domain-name
之后按回车键进入

# virsh console hello\_kvm
Connected to domain hello\_kvm
Escape character is ^]

[root@hello-kvm ~]#

按 ctrl + ] 退出

暂停/恢复
# virsh suspend domain-name
# virsh resume  domain-name

保存/加载
# virsh save domain-name filename
# virsh restore filename

编辑虚拟机xml文件
# virsh edit domain-name

使用文本编辑器修改xml 使其生效
# virsh define  /path/to/domain-name.xml

启动/停止/强制停止/重启
# virsh start     domain-name
# virsh shutdown  domain-name
# virsh reboot    domain-name
注:
直接 shutdown/reboot 是不行的，使用的 acpid 接口 ，现在没有这个 接口，需要安装
yum install -y acpid acpid-sysvinit
/etc/init.d/acpid start

# virsh destroy   domain-name

开机自启动/取消
# virsh autostart domain-name
# virsh autostart --disable domain-name

彻底删除虚拟机
# virsh destroy  domain-name
# virsh undefine domain-name
# rm -rf /etc/libvirt/qemu/domain-name.xml
# rm -rf /var/lib/libvirt/images/domain-name.img
