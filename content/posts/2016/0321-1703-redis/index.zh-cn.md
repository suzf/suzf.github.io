---
title: "Redis 常用命令总结"
slug: "redis-常用命令总结"
date: 2016-03-21T17:03:39+08:00
author: "Jeffrey Su"
description: "Redis 提供了丰富的命令（ command）对数据库和各种数据类型进行操作 下面对常用操作做出简单总结, 希望对大家有所帮助。 Redis commands -- http://redis.io/commands *** redis 默…"
categories: ["技能矩阵"]
tags: ["redis", "linux"]
---

Redis 提供了丰富的命令（ command）对数据库和各种数据类型进行操作
下面对常用操作做出简单总结, 希望对大家有所帮助。
Redis commands -- http://redis.io/commands
\*\*\* redis 默认端口 6379 \*\*\*
redis-cli -p ${port}    # 指定端口

<!--more-->

```
===== 键值 相关命令 =====
keys
返回满足给定 pattern 的所有 key
* 表示所有key
redis 127.0.0.1:1111> keys *
 1) "mylist8"
 2) "key1"
 3) "mylist2"
 4) "mylist4"
 5) "myhash"
 6) "name"
 7) "age"
 8) "mylist6"
 9) "name6"
10) "key2"
11) "mail"
12) "mylist3"
13) "mylist7"
14) "mylist"
15) "mylist5"

表达式 name* 表示所有以 name 开头的key
redis 127.0.0.1:1111> keys name*
1) "name"
2) "name6"

exists
-- 1 存在
-- 0 不存在
redis 127.0.0.1:1111> EXISTS suzf.net
(integer) 0
redis 127.0.0.1:1111> EXISTS name
(integer) 1

del
删除一个key
-- 1 删除成功
-- 0 删除失败
redis 127.0.0.1:1111> DEL name6
(integer) 1
redis 127.0.0.1:1111> EXISTS name6
(integer) 0

expire

设置一个key 的 生存时间 < 单位: s/秒 >
redis 127.0.0.1:1111> help EXPIRE

  EXPIRE key seconds
  summary: Set a key's time to live in seconds
  since: 0.09
  group: generic

redis 127.0.0.1:1111> set mykey "hello world"
OK
redis 127.0.0.1:1111> EXPIRE mykey 10
(integer) 1
redis 127.0.0.1:1111> TTL mykey
(integer) 4
redis 127.0.0.1:1111> TTL mykey
(integer) 3
redis 127.0.0.1:1111> TTL mykey
(integer) -2

move
将当前数据库中的 key 转移到其它数据库中
redis 127.0.0.1:1111> SELECT 0
OK
redis 127.0.0.1:1111> set name athena
OK
redis 127.0.0.1:1111> get name
"athena"
redis 127.0.0.1:1111> move name 1
(integer) 1
redis 127.0.0.1:1111> get name
(nil)
redis 127.0.0.1:1111> SELECT 1
OK
redis 127.0.0.1:1111[1]> get name
"athena"
redis 127.0.0.1:1111[1]>
在本例中,我先显式的选择了数据库 0,然后在这个库中设置一个 key,接下来我们将这个
key 从数据库 0 移到数据库 1,之后我们确认在数据库 0 中无此 key 了, 但在数据库 1 中存在
这个 key,说明我们转移成功了

persist
移除给定 key 的过期时间
redis 127.0.0.1:1111[1]> EXPIRE name 666
(integer) 1
redis 127.0.0.1:1111[1]> TTL name
(integer) 660
redis 127.0.0.1:1111[1]> PERSIST name
(integer) 1
redis 127.0.0.1:1111[1]> TTL name
(integer) -1

randomkey
随机返回 key 空间的一个 key
redis 127.0.0.1:1111> RANDOMKEY
"myhash"
redis 127.0.0.1:1111> RANDOMKEY
"mail"
redis 127.0.0.1:1111> RANDOMKEY
"key2"
redis 127.0.0.1:1111> RANDOMKEY
"mylist5"

rename
rename key
redis 127.0.0.1:1111> SELECT 1
OK
redis 127.0.0.1:1111[1]> keys *
1) "name"
redis 127.0.0.1:1111[1]> RENAME name name_new
OK
redis 127.0.0.1:1111[1]> keys *
1) "name_new"

type
返回值的类型
redis 127.0.0.1:1111> TYPE mylist
list
redis 127.0.0.1:1111> TYPE addr
none
redis 127.0.0.1:1111> TYPE mail
string
redis 127.0.0.1:1111> TYPE myhash
hash

===== 服务器相关命令 =====

Ping 测试连接 时候存活
-- 正常
  redis 127.0.0.1:1111> ping
  PONG

-- 错误
  #redis-cli  -p 2222 ping
  Could not connect to Redis at 127.0.0.1:2222: Connection refused

Echo
在命令行中打印内容
redis 127.0.0.1:1111> ECHO "Hello Kitty"
"Hello Kitty"

Select
选择数据库. Redis 数据库编号从 0~15,我们可以选择任意一个数据库来进行数据的存取.
redis 127.0.0.1:1111> help select

  SELECT index
  summary: Change the selected database for the current connection
  since: 0.07
  group: connection
redis 127.0.0.1:1111> SELECT 9
OK
redis 127.0.0.1:1111[9]> SELECT 16
(error) ERR invalid DB index

Quit
退出连接
redis 127.0.0.1:1111[16]> QUIT
^_^[16:15:32][root@master01 ~]#

Dbsize
返回当前数据库中 key 的条目

redis 127.0.0.1:1111> DBSIZE
(integer) 12
redis 127.0.0.1:1111> keys *
 1) "mylist8"
 2) "key1"
 3) "mylist2"
 4) "mylist4"
 5) "myhash"
 6) "mylist6"
 7) "key2"
 8) "mail"
 9) "mylist3"
10) "mylist7"
11) "mylist"
12) "mylist5"

当前数据库中有 12 个 key

Info
获取服务器信息和统计
redis 127.0.0.1:1111> INFO
# Server
redis_version:3.0.7
redis_git_sha1:00000000
...
...

# Cluster
cluster_enabled:0

# Keyspace
db0:keys=12,expires=0,avg_ttl=0
db1:keys=1,expires=0,avg_ttl=0

Monitor
实时转储接到的请求
redis 127.0.0.1:1111> MONITOR
OK
1458548482.249883 [0 192.168.9.70:44260] "PING"
1458548482.485299 [0 192.168.9.10:49031] "PING"
1458548483.309169 [0 192.168.9.70:44260] "PING"
1458548483.370627 [0 192.168.9.70:44260] "PUBLISH" "__sentinel__:hello" "192.168.9.70,6666,b5cd420208ca00f50c45b95587205235b6b2b675,9,master-1111,192.168.9.10,1111,9"
1458548483.559755 [0 192.168.9.10:49031] "PING"
1458548484.120162 [0 192.168.9.10:49031] "PUBLISH" "__sentinel__:hello" "192.168.9.10,6666,555e6555dc34bd819f8343005cd76af147ebec63,9,master-1111,192.168.9.10,1111,9"
1458548484.384204 [0 192.168.9.70:44260] "PING"
1458548484.567478 [0 192.168.9.10:49031] "PING"
1458548485.403481 [0 127.0.0.1:51102] "keys" "*"

从上面可以看出 服务器收到了 "keys *" "PUBLISH" 和 "PING" 请求

Conf get
获取当前服务器配置
redis 127.0.0.1:1111> CONFIG GET dir
1) "dir"
2) "/var/lib/redis/1111"
redis 127.0.0.1:1111> CONFIG GET timeout
1) "timeout"
2) "0"
redis 127.0.0.1:1111> CONFIG GET slaveof
1) "slaveof"
2) ""
redis 127.0.0.1:1111> CONFIG GET *
执行” config get *”即可将全部的值都显示出来

Conf set
设置临时环境变量, 重启后失效
config set $variable $value
E.g.
redis 127.0.0.1:1111> config set repl-timeout 300
OK

Flushdb
删除当前选择数据库中的所有 key
redis 127.0.0.1:1111> DBSIZE
(integer) 12
redis 127.0.0.1:1111> FLUSHDB
OK
redis 127.0.0.1:1111> DBSIZE
(integer) 0

Flushall
删除所有数据库中的所有 key
redis 127.0.0.1:1111> SELECT 1
OK
redis 127.0.0.1:1111[1]> DBSIZE
(integer) 1
redis 127.0.0.1:1111[1]> SELECT 0
OK
redis 127.0.0.1:1111> FLUSHALL
OK
redis 127.0.0.1:1111> SELECT 1
OK
redis 127.0.0.1:1111[1]> DBSIZE
(integer) 0

client list
获取客户连接列表
redis 127.0.0.1:1111> client list
id=100 addr=127.0.0.1:51251 fd=13 name= age=1315 idle=0 flags=N db=0 sub=0 psub=0 multi=-1 qbuf=0 qbuf-free=32768 obl=0 oll=0 omem=0 events=r cmd=client
id=101 addr=127.0.0.1:51897 fd=14 name= age=33 idle=33 flags=N db=0 sub=0 psub=0 multi=-1 qbuf=0 qbuf-free=0 obl=0 oll=0 omem=0 events=r cmd=NULL

client kill
终止某个客户端连接
redis 127.0.0.1:1111> client kill 127.0.0.1:51897
OK

save
立即保存数据到硬盘
redis 127.0.0.1:1111> help Save

  SAVE -
  summary: Synchronously save the dataset to disk
  since: 0.07
  group: server

redis 127.0.0.1:1111> save
OK

bgsave
异步保存数据到硬盘

lastsave
获取上次成功保存到硬盘的unix时间戳
redis 127.0.0.1:1111> lastsave
(integer) 1458550236

slowlog len
查询慢查询日志条数
redis 127.0.0.1:1111> slowlog len
(integer) 5

slowlog get
返回所有的慢查询日志,最大值取决于slowlog-max-len配置
redis 127.0.0.1:1111> slowlog get
1) 1) (integer) 4
   2) (integer) 1458550236
   3) (integer) 10857
   4) 1) "save"
2) 1) (integer) 3
   2) (integer) 1458550230
   3) (integer) 10731
   4) 1) "save"
3) 1) (integer) 2
   2) (integer) 1458548969
   3) (integer) 10589
   4) 1) "FLUSHALL"
4) 1) (integer) 1
   2) (integer) 1458539756
   3) (integer) 26752
   4) 1) "hset"
      2) "myhash"
      3) "field1"
      4) "hello"
5) 1) (integer) 0
   2) (integer) 1458270728
   3) (integer) 21491
   4) 1) "SETNX"
      2) "858C783EA7F646021E63E5A6147B7B58"
      3) "null"

slowlog get 2
打印两条慢查询日志
redis 127.0.0.1:1111> slowlog get 2
1) 1) (integer) 4
   2) (integer) 1458550236
   3) (integer) 10857
   4) 1) "save"
2) 1) (integer) 3
   2) (integer) 1458550230
   3) (integer) 10731
   4) 1) "save"

slowlog reset
清空慢查询日志信息
redis 127.0.0.1:1111> slowlog reset
OK
redis 127.0.0.1:1111> slowlog get
(empty list or set)
```
