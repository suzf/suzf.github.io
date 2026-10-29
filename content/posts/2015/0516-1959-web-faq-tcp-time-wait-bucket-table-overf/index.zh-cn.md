---
title: "Web_Faq:   TCP: time wait bucket table overflow"
slug: "web_faq-tcp-time-wait-bucket-table-overflow"
date: 2015-05-16T19:59:59+08:00
author: "Jeffrey Su"
description: "前几日 查看自己的 VPS 主机 返现 有报错信息如下： kernel: TCP: time wait bucket table overflow kernel: TCP: time wait bucket table overflow k…"
categories: ["技能矩阵"]
tags: ["faq", "web", "linux"]
---

前几日 查看自己的 VPS 主机 返现 有报错信息如下：

```text
kernel: TCP: time wait bucket table overflow
kernel: TCP: time wait bucket table overflow
kernel: TCP: time wait bucket table overflow
```

（TCP:时间等待桶表）

根据报错提示，需要更改net.ipv4.tcp\_max\_tw\_buckets这个内核参数。这个参数是系统同时保持timewait套接字的最大数量。如果超过这个数字，time-wait套接字将立刻被清除并打印警告信息。这个限制仅仅是为了防止简单的 DoS攻击，你绝对不能过分依靠它或者人为地减小这个值，如果网络实际需要大于缺省值，更应该增加这个值(如果增加了内存之后)。

解决方法：增大 tcp\_max\_tw\_buckets的值，并不是这个值越小越好，我看了我系统中TIME\_WAIT 大部是由php-fpm产生的，是属于正常的现象。
系统在同时所处理的最大timewait sockets 数目。如果超过此数的话﹐time-wait socket 会被立即砍除并且显示警告信息。之所以要设定这个限制﹐纯粹为了抵御那些简单的 DoS 攻击﹐千万不要人为的降低这个限制﹐不过﹐如果网络条件需要比默认值更多﹐则可以提高它(或许还要增加内存)。

```text
netstat -an | grep 9000 | awk '{print $6}' | sort | uniq -c | sort -rn
netstat -an | grep 80 | awk '{print $6}' | sort | uniq -c | sort -rn
```

排查步骤：

1. 查看服务器网络连接情况；

```text
# netstat -pant |awk '/^tcp/ {++state[$6]} END {for(key in state) printf("%-10s\t%d\n",key,state[key]) }'
TIME_WAIT 6798
CLOSE_WAIT 1
ESTABLISHED 592
SYN_RECV 69
CLOSING 39
LAST_ACK 19
LISTEN 107
```

2.查看内核参数

```text
#sysctl -a | grep net.ipv4.tcp_max_tw_buckets
net.ipv4.tcp_max_tw_buckets = 8192
```

改为：net.ipv4.tcp\_max\_tw\_buckets = 10000

3.使更改的内核参数生效

```text
sysctl -p
```

4. 再次查看服务器网络连接情况；

```text
# netstat -pant |awk '/^tcp/ {++state[$6]} END {for(key in state) printf("%-10s\t%d\n",key,state[key]) }'
TIME_WAIT 6644
...
```

5.再看/var/log/messages和dmesg的信息，已经不再报错了
看来net.ipv4.tcp\_max\_tw\_buckets=10000暂时是够用了

6.原因

服务器的TCP连接数，超出了内核定义最大数。
