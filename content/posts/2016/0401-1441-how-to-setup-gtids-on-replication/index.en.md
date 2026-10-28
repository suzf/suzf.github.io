---
title: "Setting Up MySQL GTID Replication: New Slave, XtraBackup and Converting Classic Replication"
slug: "how-to-setup-gtids-on-replication"
date: 2016-04-01T14:41:02+08:00
author: "Jeffrey Su"
description: "A MySQL 5.6 GTID replication lab: the my.cnf settings, a fresh master/slave pair, seeding a slave with XtraBackup and gtid_purged, and moving classic replication to GTID."
categories: ["Skills Matrix"]
tags: ["Mysql", "GTID", "linux"]
---

### Lab environment

- OS: CentOS 6.x
- MySQL: 5.6, two instances on one host (ports 3306 and 3307) run by `mysqld_multi`
- Hostname: lab.suzf.net

> *Written for MySQL 5.6. On MySQL 8.0, create the replication user with `CREATE USER` before `GRANT` (`GRANT ... IDENTIFIED BY` is gone), and from 8.0.22/8.0.23 the commands are also spelled `CHANGE REPLICATION SOURCE TO`, `START REPLICA` and `SHOW REPLICA STATUS`.*

##### Scenario 1: a new master and slave with no data

GTID replication mostly comes down to a few settings in the configuration file:

<!--more-->

```
[mysqld_multi]
mysqld = /usr/local/mysql/bin/mysqld_safe
mysqladmin = /usr/local/mysql/bin/mysqladmin
log = /usr/local/mysql/data/log/mysqld_multi.log
user = root ## Used for stopping the server via mysqladmin

# master
[mysqld3306]
socket = /usr/local/mysql/data/run/mysqld_3306.sock
port = 3306
pid-file = /usr/local/mysql/data/run/mysqld_3306.pid
datadir = /usr/local/mysql/data/mysql_3306

# set for GTID Replication
server_id = 3232237894
gtid_mode = on
enforce_gtid_consistency = on  # some CREATE TABLE forms are refused once this is on

# binlog
log-bin = /usr/local/mysql/data/binlogs/master-binlog
log-slave-updates = 1
binlog_format = row            # strongly recommended; other formats can leave the data inconsistent

# rely log
skip_slave_start=1

# slave
[mysqld3307]
socket = /usr/local/mysql/data/run/mysqld_3307.sock
port = 3307
pid-file = /usr/local/mysql/data/run/mysqld_3307.pid
datadir = /usr/local/mysql/data/mysql_3307

# set for GTID Replication
server_id = 3232237866
gtid_mode = on
enforce_gtid_consistency = on

# bin log
log-bin = /usr/local/mysql/data/binlogs/slave-binlog
log-slave-updates = 1
binlog_format = row

# rely log
skip_slave_start=1

[client]
default-character-set = utf8
```

**Restart MySQL**

```
/etc/init.d/mysqld_multi.server restart
```

**The mysqld_multi init script**

```
cat /etc/init.d/mysqld_multi.server
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

basedir=/usr/local/mysql
bindir=/usr/local/mysql/bin

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

**On the master**

```
mysql -uroot -S /usr/local/mysql/data/run/mysqld_3306.sock
mysql> GRANT REPLICATION SLAVE ON *.* TO 'repluser'@'localhost' IDENTIFIED BY 'suzf.net666';
Query OK, 0 rows affected (0.00 sec)
```

**On the slave**

With GTIDs there is no binlog file and position to look up: `MASTER_AUTO_POSITION = 1` lets the slave work out where to start.

```
mysql -uroot -S /usr/local/mysql/data/run/mysqld_3307.sock
mysql> CHANGE MASTER TO  
    -> MASTER_HOST='localhost',    
    -> MASTER_USER='repluser',    
    -> MASTER_PASSWORD='suzf.net666',    
    -> MASTER_PORT=3306,    
    -> MASTER_AUTO_POSITION = 1;
Query OK, 0 rows affected, 2 warnings (0.04 sec)
mysql> start slave;
Query OK, 0 rows affected (0.19 sec)
```

Check the result:

![gtid1](gtid1.png)

##### Scenario 2: remove replication

Stop the slave, then clear its replication settings with `RESET SLAVE ALL` (MySQL 5.6.7 and later). After that, `SHOW SLAVE STATUS` returns an empty set. If the node will later replicate from a different master, also run `RESET MASTER` so that `gtid_executed` and `gtid_purged` start out empty.

```
mysql> STOP SLAVE;
mysql> RESET SLAVE ALL;
mysql> RESET MASTER;
```

Percona's [How to create/restore a slave using GTID replication in MySQL 5.6](https://www.percona.com/blog/2013/02/08/how-to-createrestore-a-slave-using-gtid-replication-in-mysql-5-6/) walks through this, as well as seeding a slave with mysqldump and the `ERROR 1840 ... GTID_PURGED can only be set when GTID_EXECUTED is empty` error you can hit when importing the dump.

##### Scenario 3: seed a new GTID slave with XtraBackup

Preparation: one option file per instance, for innobackupex to read.

```
$mkdir  /opt/data/backup/mysql -p
$ cat 3306.cnf
[mysqld]
socket = /usr/local/mysql/data/run/mysqld_3306.sock
port = 3306
pid-file = /usr/local/mysql/data/run/mysqld_3306.pid
datadir = /usr/local/mysql/data/mysql_3306

# set for GTID Replication
server_id = 3232237894
gtid_mode = on
enforce_gtid_consistency = on

# binlog
log-bin = /usr/local/mysql/data/binlogs/master-binlog
log-slave-updates = 1
binlog_format = row

# rely log
skip_slave_start=1

[client]
default-character-set = utf8

$ cat 3307.cnf
[mysqld]
socket = /usr/local/mysql/data/run/mysqld_3307.sock
port = 3307
pid-file = /usr/local/mysql/data/run/mysqld_3307.pid
datadir = /usr/local/mysql/data/mysql_3307

# set for GTID Replication
server_id = 3232237866
gtid_mode = on
enforce_gtid_consistency = on

# bin log
log-bin = /usr/local/mysql/data/binlogs/slave-binlog
log-slave-updates = 1
binlog_format = row

# rely log
skip_slave_start=1

[client]
default-character-set = utf8
```

Take a full backup of the master:

```
$innobackupex --defaults-file=/opt/data/backup/mysql/3306.cnf --user=root  --socket=/usr/local/mysql/data/run/mysqld_3306.sock  /tmp
```

![innobackup](innobackup.png)

The file that matters here is `xtrabackup_binlog_info`. Its last field is the GTID set the backup contains:

```
$ cat /tmp/2016-04-05_15-26-40/xtrabackup_binlog_info
master-binlog.000006  191 81ee72fe-c957-11e5-ae70-0800272aa66e:1-12
```

Restore it on the slave:

```
$ innobackupex --defaults-file=/opt/data/backup/mysql/3307.cnf --user=root  --copy-back /tmp/2016-04-05_15-26-40
```

Note: `Original data directory must be empty!` The slave's data directory has to be empty before `--copy-back`.

Fix the ownership and start the instance:

```
$ chown -R mysql:mysql  /usr/local/mysql/data/mysql_3307
$ /etc/init.d/mysqld_multi.server start 3307
$ /etc/init.d/mysqld_multi.server report
Reporting MySQL servers
MySQL server from group: mysqld3306 is running
MySQL server from group: mysqld3307 is running
```

Before setting up replication, set `gtid_purged` to the GTID set from the backup, as described in the [Percona XtraBackup documentation](https://www.percona.com/doc/percona-xtrabackup/2.1/howtos/recipes_ibkx_gtid.html). If MySQL refuses, run `RESET MASTER` first:

```
mysql>  SET GLOBAL gtid_purged="81ee72fe-c957-11e5-ae70-0800272aa66e:1-12";
ERROR 1840 (HY000): @@GLOBAL.GTID_PURGED can only be set when @@GLOBAL.GTID_EXECUTED is empty.

# after the error above, run:
mysql> reset master;
Query OK, 0 rows affected (0.02 sec)

mysql>  SET GLOBAL gtid_purged="81ee72fe-c957-11e5-ae70-0800272aa66e:1-12";
Query OK, 0 rows affected (0.05 sec)

mysql> CHANGE MASTER TO  
    -> MASTER_HOST='localhost',    
    -> MASTER_USER='repluser',    
    -> MASTER_PASSWORD='suzf.net666',    
    -> MASTER_PORT=3306,    
    -> MASTER_AUTO_POSITION = 1;
Query OK, 0 rows affected, 2 warnings (0.06 sec)

mysql> SHOW WARNINGS;
+-------+------+--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| Level | Code | Message                                                                                                                                                                                                                                                                              |
+-------+------+--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| Note  | 1759 | Sending passwords in plain text without SSL/TLS is extremely insecure.                                                                                                                                                                                                               |
| Note  | 1760 | Storing MySQL user name or password information in the master info repository is not secure and is therefore not recommended. Please consider using the USER and PASSWORD connection options for START SLAVE; see the 'START SLAVE Syntax' in the MySQL Manual for more information. |
+-------+------+--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
2 rows in set (0.00 sec)
```

With classic replication (MySQL 5.5 and earlier), you would point the slave at a binlog file and position instead:

```
change master to master_host='lab.suzf.net', master_port=3306, master_user='repluser', master_password='suzf.net666',  master_log_file='mysql-bin.000006', master_log_pos=1026;
```

Start the slave and check its status:

```
mysql> start slave;
Query OK, 0 rows affected (0.01 sec)

mysql> show slave status\G
             Slave_IO_Running: Yes
            Slave_SQL_Running: Yes
      Slave_SQL_Running_State: Slave has read all relay log; waiting for the slave I/O thread to update it
           Retrieved_Gtid_Set: 81ee72fe-c957-11e5-ae70-0800272aa66e:13
            Executed_Gtid_Set: 81ee72fe-c957-11e5-ae70-0800272aa66e:1-13
                Auto_Position: 1
```

##### Scenario 4: convert classic replication to GTID replication

1. Set the GTID options in each server's configuration file as in scenario 1.
2. Make every server read-only and wait until the slaves have caught up:
   ```
   mysql> SET @@global.read_only = ON;
   ```
3. Restart the master and the slaves, one after another.
4. Point each slave at the master with auto-positioning:
   ```
   mysql> CHANGE MASTER TO
       -> MASTER_HOST = host,
       -> MASTER_PORT = port,
       -> MASTER_USER = user,
       -> MASTER_PASSWORD = password,
       -> MASTER_AUTO_POSITION = 1;
   ```
5. Start replication on the slaves:
   ```
   mysql> START SLAVE;
   ```
6. Check that replication works, then turn `read_only` off on the master.

### FAQ: skipping a transaction with GTIDs

`sql_slave_skip_counter` does not work with GTID replication. To skip a transaction that breaks the slave, commit an empty transaction with the same GTID on the slave, then restart replication:

```
mysql> STOP SLAVE;
mysql> SET gtid_next='<source_uuid>:<transaction_id>';
mysql> BEGIN; COMMIT;
mysql> SET gtid_next='AUTOMATIC';
mysql> START SLAVE;
```

Percona's [Repair MySQL 5.6 GTID replication by injecting empty transactions](https://www.percona.com/blog/2013/03/26/repair-mysql-5-6-gtid-replication-by-injecting-empty-transactions/) explains how to find the failing GTID in `SHOW SLAVE STATUS`.

References

[0] [MySQL 5.6 manual: Replication with Global Transaction Identifiers](https://dev.mysql.com/doc/refman/5.6/en/replication-gtids.html)

[1] [How to create/restore a slave using GTID replication in MySQL 5.6](https://www.percona.com/blog/2013/02/08/how-to-createrestore-a-slave-using-gtid-replication-in-mysql-5-6/)

[2] [How to create a new (or repair a broken) GTID based slave with Percona XtraBackup](http://www.percona.com/blog/2013/05/09/how-to-create-a-new-or-repair-a-broken-gtid-based-slave-with-percona-xtrabackup/)

[3] [Repair MySQL 5.6 GTID replication by injecting empty transactions](https://www.percona.com/blog/2013/03/26/repair-mysql-5-6-gtid-replication-by-injecting-empty-transactions/)
