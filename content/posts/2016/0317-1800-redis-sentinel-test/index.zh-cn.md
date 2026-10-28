---
title: "Redis Sentinel Test"
slug: "redis-sentinel-test"
date: 2016-03-17T18:00:00+08:00
author: "Jeffrey Su"
description: "Redis Sentinel 是一套用于管理Redis实例的分布式系统,主要完成3项任务: 1. Monitoring:持续监控Redis master或slave实例的运行情况是否符合预期 2. Notification:若被监控的Red…"
categories: ["技能矩阵"]
tags: ["redis", "linux"]
---

Redis Sentinel 是一套用于管理Redis实例的分布式系统,主要完成3项任务:

1. Monitoring:持续监控Redis master或slave实例的运行情况是否符合预期
2. Notification:若被监控的Redis实例运行异常,sentinel会通过API通知外界（人或程序）
3. Automation failover:若master实例故障,sentinel会重新选主并启动自动故障切换:选择slave-priority最小的那个slave实例并将其提升为master,同时修改其它slave的配置,使其master配置项指向新的master,当old master恢复重启后,会自动降级为new master的slave.最后,根据配置,Redis Sentinel还会将新的master地址通知给当前正在访问Redis的应用程序.

<!--more-->

Raft分布式算法

1. 主要用途:用于分布式系统,系统容错,以及选出领头羊
2. 作者:Diego Ongaro,毕业于哈佛
3. 目前用到这个算法的项目有:
a. CoreOS
b. ectd : a distributed, consistent shared configuration
c. LogCabin : 分布式存储系统
d. redis sentinel : redis 的监控系统

Sentinel使用的Raft算法核心: 原则

1. 所有sentinel都有选举的领头羊的权利
2. 每个sentinel都会要求其他sentinel选举自己为领头羊(主要由发现redis客观下线的sentinel先发起选举)
3. 每个sentinel只有一次选举的机会
4. 采用先到先得的原则
5. 一旦加入到系统了,则不会自动清除(这一点很重要, why?)
6. 每个sentinel都有唯一的uid,不会因为重启而变更
7. 达到领头羊的条件是 N/2 + 1个sentinel选择了自己
8. 采用配置纪元,如果一次选举出现脑裂,则配置纪元会递增,进入下一次选举,所有sentinel都会处于统一配置纪元,以最新的为标准.

Sentinel 配置样例

```
  port 26379
  dir /tmp
  sentinel monitor mymaster 127.0.0.1 6379 2
  sentinel down-after-milliseconds mymaster 30000
  sentinel parallel-syncs mymaster 1
  sentinel failover-timeout mymaster 180000
  sentinel notification-script myredis <script-path>
```

其中:
port: 指定sentinel的侦听端口（即与redis server或client建立tcp连接的端口）
dir: 工作路径,sentinel一般指定/tmp比较简单
monitor: 指定sentinel要monitor的redis实例,包括一个redis实例的别名（alias）及redis实例的ip+port,该行最后的数字2表示至少2个setinel实例同时检测到redis server异常时,才将redis server的状态判决为real fail.也即,若这里配置为2,但实际部署中sentinel只部署了1套,则即使redis实例已经挂掉,sentinel也不会给出任何警告.这一点需要特别引起注意.
down-after-milliseconds: 指定sentinel监控到redis实例持续异常多长时间后,会判决其状态为down.若实际业务需要sentinel尽快判决出redis实例异常,则该值可适当配小.
failover-timeout: 若sentinel在该配置值内未能完成failover操作（即故障时master/slave自动切换）,则认为本次failover失败.该配置有4个用途,具体可参考sentinel.conf中的说明,限于篇幅,此处不再赘述.
parallel-syncs: 指定failover过程中,同时被sentinel reconfigure的最大slave实例数.由于reconfigure过程中,对应的slave会中断响应客户端请求,故为避免所有的slave同时不可用,该值需适当配小.
notification-script: 指定sentinel检测到master-name指向的实例异常时,调用的报警脚本.该配置项可选,但线上系统建议配置.

启动 sentinel的方法

当前Redis stable版已经自带了redis-sentinel这个工具.虽然 Redis Sentinel 已经提供了一个单独的可执行文件 redis-sentinel , 但实际上它只是一个运行在特殊模式下的 Redis实例, 你可以在启动一个普通 Redis实例时通过给定 –sentinel 选项来启动 Redis Sentinel 实例.也就是说:
redis-sentinel /path/to/sentinel.conf
等同于
redis-server /path/to/sentinel.conf --sentinel
其中sentinel.conf是redis的配置文件,Redis sentinel会需要写入配置文件来保存sentinel的当前状态.当配置文件无法写入时,Sentinel启动失败.

sentinel 测试
实验环境 < one master / Three slaves / two sentinels >:
a. one master（slave-priority为90）部署在ip为192.168.9.10的机器上；
b.Three slaves（slave-priority分别为100）的均部署在ip为192.168.9.70的机器上；
c. 启用两个sentinel进程监控redis集群状态

配置 sentinel

Sentinel可以通过master Redis实例来获得它的从实例的信息.所以每一个Sentinel只配置主实例的监控即可.Sentinel之间端口有所不同.

```
  port 6666
  daemonize yes
  logfile "/var/log/redis/sentinel-6666.log"
 
  #master 1111
  sentinel monitor master-1111 192.168.9.10 11111 1
  sentinel config-epoch master-1111 6
  sentinel leader-epoch master-1111 6
  sentinel known-slave master-1111 192.168.9.70 2222
```

启动 sentinel
配置文件修改完成后,启动各监控进程即可,例如:
redis-server /etc/redis/sentinel-6666.conf

连接Sentinel和主动failover

在默认情况下,Sentinel 使用TCP端口26379（普通 Redis 服务器使用的是 6379）.
Sentinel 接受 Redis 协议格式的命令请求,所以你可以使用 redis-cli 或者任何其他 Redis 客户端来与 Sentinel 进行通讯.
有两种方式可以和 Sentinel 进行通讯:
第一种方法是通过直接发送命令来查询被监视 Redis 服务器的当前状态, 以及进行主动转移等操作.这些命令包括:

SENTINEL masters
列出所有被监视的主Redis服务实例,以及这些主服务实例的当前状态.

SENTINEL slaves
列出给定主服务实例的所有从实例,以及这些从实例的当前状态.

SENTINEL get-master-addr-by-name
返回给定名字的主实例的 IP 地址和端口号. 如果这个主实例正在执行故障转移操作, 或者针对这个主实例的故障转移操作已经完成, 那么这个命令返回新的主服务器的 IP 地址和端口号.

SENTINEL reset:
重置所有名字和给定模式 pattern 相匹配的主服务器. pattern 参数是一个 Glob 风格的模式. 重置操作清除该sentinel的所保存的所有状态信息,并进行一次重新的发现过程.

SENTINEL failover
进行一次主动的failover.即在不询问其他 Sentinel 意见的情况下, 强制开始一次自动故障迁移 .发起故障转移的 Sentinel 会向其他 Sentinel 发送一个新的配置,其他 Sentinel 会根据这个配置进行相应的更新.^\_^[17:19:25][root@master01 ~]#redis-cli  -p 6666

```
redis 127.0.0.1:6666> SENTINEL masters
1)  1) "name"
2) "master-1111"
3) "ip"
4) "192.168.9.10"
5) "port"
6) "1111"
7) "runid"
8) "5d6c2f08547ffe9446eb54c85dc40959e66b203d"
9) "flags"
10) "master"
11) "pending-commands"
12) "0"
13) "last-ping-sent"
14) "0"
15) "last-ok-ping-reply"
16) "947"
17) "last-ping-reply"
18) "947"
19) "down-after-milliseconds"
20) "30000"
21) "info-refresh"
22) "6259"
23) "role-reported"
24) "master"
25) "role-reported-time"
26) "126884"
27) "config-epoch"
28) "7"
29) "num-slaves"
30) "3"
31) "num-other-sentinels"
32) "1"
33) "quorum"
34) "1"
35) "failover-timeout"
36) "180000"
37) "parallel-syncs"
38) "1"

redis 127.0.0.1:6666> SENTINEL slaves master-1111
1)  1) "name"
2) "192.168.9.10:1112"
3) "ip"
4) "192.168.9.10"
5) "port"
6) "1112"
7) "runid"
8) ""
9) "flags"
10) "s_down,slave,disconnected"
11) "pending-commands"
12) "0"
13) "last-ping-sent"
14) "215549"
15) "last-ok-ping-reply"
16) "215549"
17) "last-ping-reply"
18) "215549"
19) "s-down-time"
20) "185544"
21) "down-after-milliseconds"
22) "30000"
23) "info-refresh"
24) "1458206565223"
25) "role-reported"
26) "slave"
27) "role-reported-time"
28) "215549"
29) "master-link-down-time"
30) "0"
31) "master-link-status"
32) "err"
33) "master-host"
34) "?"
35) "master-port"
36) "0"
37) "slave-priority"
38) "100"
39) "slave-repl-offset"
40) "0"
2)  1) "name"
2) "192.168.9.70:2222"
3) "ip"
4) "192.168.9.70"
5) "port"
6) "2222"
7) "runid"
8) ""
9) "flags"
10) "s_down,slave,disconnected"
11) "pending-commands"
12) "0"
13) "last-ping-sent"
14) "215549"
15) "last-ok-ping-reply"
16) "215549"
17) "last-ping-reply"
18) "215549"
19) "s-down-time"
20) "185544"
21) "down-after-milliseconds"
22) "30000"
23) "info-refresh"
24) "1458206565223"
25) "role-reported"
26) "slave"
27) "role-reported-time"
28) "215549"
29) "master-link-down-time"
30) "0"
31) "master-link-status"
32) "err"
33) "master-host"
34) "?"
35) "master-port"
36) "0"
37) "slave-priority"
38) "100"
39) "slave-repl-offset"
40) "0"
3)  1) "name"
2) "192.168.9.70:2223"
3) "ip"
4) "192.168.9.70"
5) "port"
6) "2223"
7) "runid"
8) "9987aebafc55d750145a61f9109cf7d9fb7c8613"
9) "flags"
10) "slave"
11) "pending-commands"
12) "0"
13) "last-ping-sent"
14) "0"
15) "last-ok-ping-reply"
16) "372"
17) "last-ping-reply"
18) "372"
19) "down-after-milliseconds"
20) "30000"
21) "info-refresh"
22) "4616"
23) "role-reported"
24) "slave"
25) "role-reported-time"
26) "215549"
27) "master-link-down-time"
28) "0"
29) "master-link-status"
30) "ok"
31) "master-host"
32) "192.168.9.10"
33) "master-port"
34) "1111"
35) "slave-priority"
36) "100"
37) "slave-repl-offset"
38) "29082"

查看当前的master
redis 127.0.0.1:6666>  SENTINEL get-master-addr-by-name master-1111
1) "192.168.9.10"
2) "1111"
```

使用发布与订阅功能, 通过接收 Sentinel 发送的通知: 当执行故障转移操作, 或者某个被监视的实例被判断为主观下线或者客观下线时, Sentinel 就会发送相应的信息.
一个频道能够接收和这个频道的名字相同的事件. 比如说,名为 +sdown 的频道就可以接收所有实例进入主观下线（SDOWN）状态的事件.
通过执行 PSUBSCRIBE \* 命令可以接收所有事件信息.例如：

```
^_^[17:50:13][root@master01 ~]#redis-cli -p 6666 info| grep 192
master0:name=master-1111,status=ok,address=192.168.9.10:1111,slaves=3,sentinels=2

^_^[17:50:21][root@master01 ~]#redis-cli -p 6666 sentinel failover master-1111
OK

@_@[17:50:09][root@master01 ~]#redis-cli -p 6666
redis 127.0.0.1:6666>  SENTINEL get-master-addr-by-name master-1111
1) "192.168.9.10"
2) "1111"
redis 127.0.0.1:6666> PSUBSCRIBE *
Reading messages... (press Ctrl-C to quit)
1) "psubscribe"
2) "*"
3) (integer) 1
1) "pmessage"
2) "*"
3) "+new-epoch"
4) "8"
1) "pmessage"
2) "*"
3) "+try-failover"
4) "master master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+vote-for-leader"
4) "691dc32d3a3c1afdc5b18a8e5541c885aa04c487 8"
1) "pmessage"
2) "*"
3) "+elected-leader"
4) "master master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+failover-state-select-slave"
4) "master master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+selected-slave"
4) "slave 192.168.9.10:1112 192.168.9.10 1112 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+failover-state-send-slaveof-noone"
4) "slave 192.168.9.10:1112 192.168.9.10 1112 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+failover-state-wait-promotion"
4) "slave 192.168.9.10:1112 192.168.9.10 1112 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "-role-change"
4) "slave 192.168.9.10:1112 192.168.9.10 1112 @ master-1111 192.168.9.10 1111 new reported role is master"
1) "pmessage"
2) "*"
3) "+promoted-slave"
4) "slave 192.168.9.10:1112 192.168.9.10 1112 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+failover-state-reconf-slaves"
4) "master master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+slave-reconf-sent"
4) "slave 192.168.9.70:2222 192.168.9.70 2222 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+slave-reconf-inprog"
4) "slave 192.168.9.70:2222 192.168.9.70 2222 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+slave-reconf-done"
4) "slave 192.168.9.70:2222 192.168.9.70 2222 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+slave-reconf-sent"
4) "slave 192.168.9.70:2223 192.168.9.70 2223 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+slave-reconf-inprog"
4) "slave 192.168.9.70:2223 192.168.9.70 2223 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+slave-reconf-done"
4) "slave 192.168.9.70:2223 192.168.9.70 2223 @ master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+failover-end"
4) "master master-1111 192.168.9.10 1111"
1) "pmessage"
2) "*"
3) "+switch-master"
4) "master-1111 192.168.9.10 1111 192.168.9.10 1112"
1) "pmessage"
2) "*"
3) "+slave"
4) "slave 192.168.9.70:2222 192.168.9.70 2222 @ master-1111 192.168.9.10 1112"
1) "pmessage"
2) "*"
3) "+slave"
4) "slave 192.168.9.70:2223 192.168.9.70 2223 @ master-1111 192.168.9.10 1112"
1) "pmessage"
2) "*"
3) "+slave"
4) "slave 192.168.9.10:1111 192.168.9.10 1111 @ master-1111 192.168.9.10 1112"
1) "pmessage"
2) "*"
3) "-role-change"
4) "slave 192.168.9.10:1111 192.168.9.10 1111 @ master-1111 192.168.9.10 1112 new reported role is master"
1) "pmessage"
2) "*"
3) "+role-change"
4) "slave 192.168.9.10:1111 192.168.9.10 1111 @ master-1111 192.168.9.10 1112 new reported role is slave"
```

一次故障转移操作由以下步骤组成：
(1). 由sentinel主动发起failover或者发现主服务器已经进入客观下线状态.
(2). sentinel对我们的当前纪元(epoch)进行自增,并尝试在这个纪元中当选为此次failover的总指挥.
(3). 如果当选失败, 那么在设定的故障迁移超时时间的两倍之后, 重新尝试当选. 如果当选成功, 那么执行以下步骤.
(4). 选出一个从redis实例,并将它升级为主redis实例.
(5). 向被选中的从redis实例发送 SLAVEOF NO ONE 命令,让它转变为主redis实例.
(6). 通过发布与订阅功能, 将更新后的配置传播给所有其他 Sentinel , 其他 Sentinel 对它们自己的配置进行更新.
(7). 向已下线主服务器的从服务器发送SLAVEOF命令, 让它们去复制新的主服务器.
(8). 当所有从redis实例都已经开始复制新的主redis实例时, 领头Sentinel 终止这次故障迁移操作.

FAQ:
若master实例故障,则最好等sentinel选出new master且稳定后（选新主并完成切换的时间与配置有关,典型值在1分钟之内）,再重启old master,避免引发sentinel的误判,导致整个系统无法选出new master.

最大内存问题:要设置好最大内存,以防不停的申请内存,造成系统内存都被用完.

Fork进程问题:'vm.overcommit\_memory = 1'这一个选项要加到系统的配置中,防止fork因内存不足而失败.

密码问题:需要设置复杂一些,防止暴力破解.
