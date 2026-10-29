---
title: "Mysql 单机多实例详解"
slug: "mysql-单机多实例详解"
date: 2015-12-02T13:18:29+08:00
author: "Jeffrey Su"
description: "应用场景 采用了数据伪分布式架构的原因，而项目启动初期又不一定有那多的用户量，为此先一组物理数据库服务器，但部署多个实例，方便后续迁移 为规避mysql对SMP架构不支持的缺陷，使用多实例绑定处理器的办法，把不同的数据库分配到不同的实例上提…"
categories: ["技能矩阵"]
tags: ["Mysql", "linux"]
---

### 应用场景

- 采用了数据伪分布式架构的原因，而项目启动初期又不一定有那多的用户量，为此先一组物理数据库服务器，但部署多个实例，方便后续迁移
- 为规避mysql对SMP架构不支持的缺陷，使用多实例绑定处理器的办法，把不同的数据库分配到不同的实例上提供数据服务
- 一台物理数据库服务器支撑多个数据库的数据服务，为提高mysql复制的从机的恢复效率，采用多实例部署
- 已经为双主复制的mysql数据库服务器架构，想部分重要业务的数据多一份异地机房的热备份，而mysql复制暂不支持多主的复制模式，且不给用户提供服务，为有效控制成本，会考虑异地机房部署一台性能超好的物理服务器，甚至外加磁盘柜的方式，为此也会部署多实例
- 传统游戏行业的MMO/MMORPG，以及Web Game，每一个服都对应一个数据库，而可能要做很多数据查询和数据订正的工作，为减少维护而出错的概率，也可能采用多实例部署的方式，按区的概念分配数据库

<!--more-->

### 实验环境

- 在一台服务器上通过源码编译安装一个版本为5.6的MySQL数据库
- 将所有配置文件与数据等均存放在/opt/mysql，便于今后实现快速迁移、整体备份和快速复制
- 在同一个MySQL中运行两个实例，一个绑定在端口3306，另一个绑定在端口3307
- 绑定在3306端口的实例，不开启binlog，数据存放在/opt/mysql/data/mysql3306
- 绑定在3307端口的实例，开启binlog，  数据存放在/opt/mysql/data/mysql3307
- 两个实例均采用InnoDB作为默认的存储引擎，字符编码采用UTF-8；
- 两个实例均采用相同的性能优化配置参数

### 注意事项

- 在编译安装时，将数据库的配置文件my.cnf以及data目录等均指向到/opt/mysql目录
- 通过mysqld\_multi的方式来管理两个不同的实例，采用相同的配置文件共享性能优化配置参数
- 在同一个配置文件中，利用[mysqld1]与[mysqld2]标签实现不同实例的差异化配置

### 环境准备

安装依赖包

```text
# yum install -y autoconf* automake* zlib* libxml* ncurses-devel* libgcrypt* libtool* openssl* cmake
```

建立mysql安装目录及数据存放目录

```text
# mkdir /opt/mysql
# mkdir /opt/mysql/data
```

创建用户和用户组

```text
# groupadd mysql
# useradd -g mysql mysql
```

赋予数据存放目录权限

```text
# chown mysql:mysql -R /opt/mysql/data
```

### 开始编译安装 MySQL

通过http://www.mysql.com/downloads/mysql官方网址 下载mysql源码包

```text
# wget http://cdn.mysql.com//Downloads/MySQL-5.6/mysql-5.6.28.tar.gz
# tar zxvf mysql-5.6.28.tar.gz
# cd mysql-5.6.28
# cmake -DCMAKE_INSTALL_PREFIX=/opt/mysql \
-DSYSCONFDIR=/opt/mysql/etc \
-DMYSQL_DATADIR=/opt/mysql/data \
-DMYSQL_TCP_PORT=3306 \
-DMYSQL_UNIX_ADDR=/tmp/mysqld.sock \
-DMYSQL_USER=mysql \
-DEXTRA_CHARSETS=all \
-DWITH_READLINE=1 \
-DWITH_SSL=system \
-DWITH_EMBEDDED_SERVER=1 \
-DENABLED_LOCAL_INFILE=1 \
-DWITH_INNOBASE_STORAGE_ENGINE=1

# make && make install
```

### 创建支持多实例的配置文件

```text
# cd /opt/mysql/
```

删除默认的data目录

```text
# rm -rf data/*
```

创建需要的目录

```text
# cd data
# mkdir etc tmp run log binlogs mysql3306 mysql3307
# chown -R mysql:mysql tmp run log binlogs mysql3306 mysql3307
```

创建my.cnf配置文件

```text
# vim etc/my.cnf
## This server may run 2+ separate instances
## So we use mysqld_multi to manage their services

[mysqld_multi]
mysqld = /opt/mysql/bin/mysqld_safe
mysqladmin = /opt/mysql/bin/mysqladmin
log = /opt/mysql/data/log/mysqld_multi.log
user = root ## Used for stopping the server via mysqladmin
#password =

## This is the general purpose database
## The locations are default
# They are left in [mysqld] in case the server is started normally instead of by mysqld_multi
[mysqld1]
socket = /opt/mysql/data/run/mysql_3306.sock
port = 3306
pid-file = /opt/mysql/data/run/mysql_3306.pid
datadir = /opt/mysql/data/mysql3306
lc-messages-dir = /opt/mysql/share/english

## These support master - master replication
#auto-increment-increment = 4
#auto-increment-offset = 1  ## Since it is master 1
#log-bin = /opt/mysql/data/binlogs/bin-log-mysqld-3306
#log-bin-index = /opt/mysql/data/binlogs/bin-log-mysqld3306.index
#binlog-do-db = ## Leave this blank if you want to control it on slave

## This is exlusively for mysqld2
## It is on 3307 with data directory /opt/mysqld/data/mysql3307
[mysqld2]
socket = /opt/mysql/data/run/mysql_3307.sock
port = 3307
pid-file = /opt/mysql/data/run/mysql_3307.pid
datadir = /opt/mysql/data/mysql3307
lc-messages-dir = /opt/mysql/share/english

## Disable DNS lookups
#skip-name-resolve

## These support master - slave replication
log-bin = /opt/mysql/data/binlogs/bin-log-mysql-3307
log-bin-index = /opt/mysql/data/binlogs/bin-log-mysql-3307.index
#binlog-do-db =  ## Leave this blank if you want to control it on slave

## Relay log settings
#relay-log = /opt/mysql/data/log/relay-log-mysql-3307
#relay-log-index = /opt/mysql/data/log/relay-log-mysql-3307.index
#relay-log-space-limit = 4G

## Slow query log settings
#log-slow-queries = /opt/mysql/data/log/slow-log-mysql-3307
#long_query_time = 2
#log-queries-not-using-indexes

## The rest of the my.cnf is shared
## Here follows entries for some specific programs
## The MySQL server
[mysqld]
basedir = /opt/mysql
tmpdir = /opt/mysql/data/tmp
socket = /opt/mysql/data/run/mysqld.sock
port = 3306
pid-file = /opt/mysql/data/run/mysqld.pid
datadir = /opt/mysql/data
lc-messages-dir = /opt/mysql/share/english

skip-external-locking
key_buffer_size = 16K
max_allowed_packet = 64M
table_open_cache = 4
sort_buffer_size = 64K
read_buffer_size = 256K
read_rnd_buffer_size = 256K
net_buffer_length = 2K
thread_stack = 128K

## Increase the max connections
max_connections = 1024

## Increase the max connect errors
max_connect_errors = 10000

## Increase the connect timeout
connect_timeout = 10

## Decrease the timeout and increase the retrieves of replication
slave-net-timeout = 60
master-connect-retry = 10

## The expiration time for logs, including binlogs
expire_logs_days = 14

## Set the character as utf8
character-set-server = utf8
collation-server = utf8_unicode_ci

## This is usually only needed when setting up chained replication
#log-slave-updates

## Enable this to make replication more resilient against server crashes and restarts
## but can cause higher I/O on the server
#sync_binlog = 1

## The server id, should be unique in same network
server-id = 1

## Set this to force MySQL to use a particular engine/table-type for new tables
## This setting can still be overridden by specifying the engine explicitly
## in the CREATE TABLE statement
default-storage-engine = INNODB

## Enable Per Table Data for InnoDB to shrink ibdata1
innodb_file_per_table = 1

## Set the max size of each binlog file
max_binlog_size = 1024M

## Set the binlog format
binlog_format = ROW

## Uncomment the following if you are using InnoDB tables
#innodb_data_home_dir = /opt/mysql/data
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = /opt/mysql/data
## You can set .._buffer_pool_size up to 50 - 80 % of RAM
## but beware of setting memory usage too high
innodb_buffer_pool_size = 16M
innodb_additional_mem_pool_size = 2M
## Set .._log_file_size to 25 % of buffer pool size
innodb_log_file_size = 5M
innodb_log_buffer_size = 8M
innodb_flush_log_at_trx_commit = 1
innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 64M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 8M
sort_buffer_size = 8M

[mysqlhotcopy]
interactive-timeout

[mysql.server]
user = mysql

[mysqld_safe]
log-error = /opt/mysql/data/log/mysqld.log
pid-file = /opt/mysql/data/run/mysqld.pid
open-files-limit = 8192

[client]
default-character-set = utf8
```

修改my.cnf读写权限，避免普通用户获取到MySQL密码

```text
# chown -R root:root /opt/mysql/etc
# chmod 600 /opt/mysql/etc/my.cnf
```

### 初始化数据库

切换到mysql用户

```text
# su - mysql
```

进入MySQL主目录

```text
# cd /opt/mysql/
```

初始化实例[mysqld1]

```text
# scripts/mysql_install_db --basedir=/opt/mysql --user=mysql --datadir=/opt/mysql/data/mysql3306
```

初始化实例[mysqld2]

```text
# scripts/mysql_install_db --basedir=/opt/mysql --user=mysql --datadir=/opt/mysql/data/mysql3307
```

返回到root

```text
# exit
```

### 创建mysqld\_multi.server脚本

```text
# mkdir /opt/mysql/init.d/ && cp support-files/mysqld_multi.server /opt/mysql/init.d/
```

```text
# vim /opt/mysql/init.d/mysqld_multi.server
#!/bin/sh
#
# A simple startup script for mysqld_multi by Tim Smith and Jani Tolonen.
# This script assumes that my.cnf file exists either in /etc/my.cnf or
# /root/.my.cnf and has groups [mysqld_multi] and [mysqldN]. See the
# mysqld_multi documentation for detailed instructions.
#
# This script can be used as /etc/init.d/mysql.server
#
# Comments to support chkconfig on RedHat Linux
# chkconfig: 2345 64 36
# description: A very fast and reliable SQL database engine.
#
# Version 1.0
#

basedir=/opt/mysql
bindir=/opt/mysql/bin

conf=$basedir/data/etc/my.cnf
export PATH=$PATH:$bindir

if test -x $bindir/mysqld_multi
then
mysqld_multi="$bindir/mysqld_multi";
else
echo "Can't execute $bindir/mysqld_multi from dir $basedir";
exit;
fi

case "$1" in
'start' )
"$mysqld_multi" --defaults-extra-file=$conf start $2
;;
'stop' )
"$mysqld_multi" --defaults-extra-file=$conf stop $2
;;
'report' )
"$mysqld_multi" --defaults-extra-file=$conf report $2
;;
'restart' )
"$mysqld_multi" --defaults-extra-file=$conf stop $2
"$mysqld_multi" --defaults-extra-file=$conf start $2
;;
*)
echo "Usage: $0 {start|stop|report|restart}" >&2
;;
esac
```

### 整体备份MySQL

```text
# cd /opt/
# tar czvf mysql_5.6.28_full.tar.gz mysql/
```

备份完成后，直接将mysql\_5.6.28\_full.tar.gz拿到其他服务器上，解压后便可以直接启用。

### 管理MySQL实例

同时 启动/关闭 实例 [mysqld1] 与 [mysqld2]：

```text
# /opt/mysql/init.d/mysqld_multi.server start 1,2
```

然后，可以看到两个MySQL实例都已经成功的启动了。

```text
# netstat -lntp | grep mysqld
tcp        0      0 :::3307                     :::*                        LISTEN      17877/mysqld
tcp        0      0 :::3306                     :::*                        LISTEN      17874/mysqld
```

同时 关闭 实例 [mysqld1] 与 [mysqld2]：

```text
# /opt/mysql/init.d/mysqld_multi.server stop 1,2
```

仅 启动/关闭 实例[mysqld1]：

```text
# /opt/mysql/init.d/mysqld_multi.server start 1
# /opt/mysql/init.d/mysqld_multi.server stop 1
```

### 登陆MySQL实例

通过以下方式登陆不同的实例：
tcp

```text
# /opt/mysql/bin/mysql -uroot -h127.0.0.1 -P3306 -p
```

socket

```text
# /opt/mysql/bin/mysql -uroot -h127.0.0.1 -S  /opt/mysql/data/run/mysql_3306.sock -p
```

### 其他初始化设置

1. 为MySQL的root帐户设置初始密码

```text
# /opt/mysql/bin/mysqladmin -u root -h127.0.0.1 -P3306 password 'new-password'
```

2. 修改my.cnf配置文件中MySQL的root账户密码

```text
# vim /opt/mysql/etc/my.cnf
user = root ## Used for stopping the server via mysqladmin
password = new-password
```

3. 删除匿名连接的空密码帐号
分别登陆实例[mysqld1]与[mysqld2]，执行以下命令：

```text
mysql>use mysql; //选择系统数据库mysql
mysql>select Host,User,Password from user; //查看所有用户
mysql>delete from user where password="";
mysql>flush privileges; //刷新权限
mysql>select Host,User,Password from user; //确认密码为空的用户是否已全部删除
mysql>exit;
```

### 经验总结

1.采用源码编译安装MySQL，可能在第一次会花费较多的时间，但却是非常值得的，因为我们可以自己组织所有MySQL相关文件的位置；并且经过源码编译安装后的MySQL，可以直接复制到其它服务器上运行，大大方便了我们今后的迁移、备份和新服务器的配置；

2.本文中仅仅用了两个实例[mysqld1]与[mysqld2]来举例，实际上我们可以通过这样的方式，实现[mysqld3],[mysqld4],[mysqld5]...等更多的实例；

3.MySQL自带了几个不同的配置文件，放置在/opt/mysql/support-files目录下，分别是my-huge.cnf,my-innodb-heavy-4G.cnf,my-large.cnf,my-medium.cnf,my-small.cnf，通过名称我们可以很直观的了解到他们是针对不同的服务器配置的，本文中仅有的一点关于InnoDB的配置，是取自于my-small.cnf的，因为我是在虚拟机上进行的设置；在生产环境中，我们可以通过参考my-huge.cnf或my-innodb-heavy-4G.cnf中的部分参数配置，来对服务器进行优化；

4.关于MySQL缓存参数的优化，主要用于提升I/O能力，可以参考这里：http://heylinux.com/archives/1389.html

5.在单机运行多实例的情况下，切忌使用 mysql -hlocalhost 或 直接忽略-h参数 登陆服务器，这应该算是MySQL的一个bug，就是如果使用localhost或忽略-h参数，而不是指定127.0.0.1的话，即使选择的端口是3307，还是会登陆到3306中去，因此应尽量避免这种混乱的产生，统一用127.0.0.1绑定端口 或 采用socket 来登陆；
