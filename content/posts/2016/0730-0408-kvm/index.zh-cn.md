---
title: "KVM 网络管理"
slug: "kvm-网络管理"
date: 2016-07-30T04:08:58+08:00
author: "Jeffrey Su"
description: "KVM 客户机网络连接有两种方式，： 用户网络（User Networking）：让虚拟机访问主机、互联网或本地网络上的资源的简单方法，但是不能从网络或其他的客户机访问客户机，性能上也需要大的调整。NAT方式。 虚拟网桥（Virtual B…"
categories: ["技能矩阵"]
tags: ["KVM", "linux"]
---

KVM 客户机网络连接有两种方式，：
用户网络（User Networking）：让虚拟机访问主机、互联网或本地网络上的资源的简单方法，但是不能从网络或其他的客户机访问客户机，性能上也需要大的调整。NAT方式。
虚拟网桥（Virtual Bridge）：这种方式要比用户网络复杂一些，但是设置好后客户机与互联网，客户机与主机之间的通信都很容易。Bridge方式。

注意：kvm安装后的默认是NAT方式，网桥方式需要手动配置

NAT方式

Bridge方式
Bridge方式原理

Bridge方式即虚拟网桥的网络连接方式，是客户机和子网里面的机器能够互相通信。可以使虚拟机成为网络中具有独立IP的主机。桥接网络（也叫物理设备共享）被用作把一个物理设备复制到一台虚拟机。网桥多用作高级设置，特别是主机多个网络接口的情况。

目前版本的NetworkManger 不支持配置桥接网络功能，如何需要配置桥接网络，请停用 NetworkManger 服务，改用network 服务来管理网络！

Bridge方式网络的配置

1 编辑修改网络设备脚本文件，增加网桥设备br0 CentOS发行版配置文件 /etc/sysconfig/network-scripts/ifcfg-br0

DEVICE="br0"
TYPE="Bridge"
BOOTPROTO=static
IPADDR=10.1.83.205
PREFIX=22
GATEWAY=10.1.80.254
DNS1=59.108.119.3
IPV4\_FAILURE\_FATAL=yes
IPV6INIT=no
NAME=br0
ONBOOT=yes
DELAY=0

2 编辑修改网络设备脚本文件，修改网卡设备eth0 CentOS发行版配置文件 /etc/sysconfig/network-scripts/ifcfg-eth0

DEVICE="eth0"
TYPE=Ethernet
NM\_CONTROLLED="yes"
BRIDGE="br0"
BOOTPROTO=none
DEFROUTE=yes
IPV4\_FAILURE\_FATAL=yes
IPV6INIT=no
NAME=system-eth0
UUID=611d95bc-0d27-4536-b012-c5d4994c5815
ONBOOT=yes
LAST\_CONNECT=1350313129

NM\_CONTROLLED这个属性值，根据RedHat公司的文档是必须设置为“no”的（这个值为“yes”表示可以由服务NetworkManager来管理。NetworkManager服务不支持桥接，所以要设置为“no”。），但实际上发现设置为“yes”没有问题。通讯正常。 3、重启网络服务

service network restart

4、校验桥接接口

[root@localhost ~]# brctl show
bridge name bridge id   STP enabled interfaces
br0   8000.003048c68ab0 no    eth0
vnet0
vnet1

注意事项

IP配置在桥接器上,对应的网卡不需要配置IP；
所有桥接器，物理网卡都必须处于running状态;
客户机安装时注意，网络要选择用br0桥接方式;
保证宿主机IP和虚拟机IP处于同一网段
