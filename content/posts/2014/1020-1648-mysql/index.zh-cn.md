---
title: "MYSQL 常用总结"
slug: "mysql-常用总结-基础"
date: 2014-10-20T16:48:10+08:00
author: "Jeffrey Su"
description: "文章是之前总结的，还不是很完善。对于新手来说也许有一些帮助吧。 文章难免会出现一些错误，请大家指出。"
categories: ["技能矩阵"]
tags: ["Mysql", "linux"]
---

文章是之前总结的，还不是很完善。对于新手来说也许有一些帮助吧。

文章难免会出现一些错误，请大家指出。

<!--more-->

##### Mysql 忘记root密码

在/etc/my.cfg [mysqld]下面添加
skip-grant-tables
或是
skip-grant

重启MySQL
use mysql;
UPDATE user SET Password = password ( 'new-password' ) WHERE User = 'root' ;
mysql flush privileges;
将my.cfg文件修改回来 ，重启MySQL即可。

二、在启动Mysql服务器时加上参数--skip-grant-tables来跳过授权表的验证
(./safe\_mysqld --skip-grant-tables &)，这样我们就可以直接登陆Mysql服务器，
然后再修改root用户的口令，重启Mysql就可以用新口令登陆了。

添加环境变量
PATH=$PATH:/usr/local/mysql/bin 加入到/etc/profile中

只需本机使用Mysql服务
在启动时还可以加上--skip-networking参数使Mysql不监听任何TCP/IP连接
(./safe\_mysqld --skip-networking &)，增加安全性。（非常推荐）

##### 查看支持的存储引擎

```
mysql> show engines;
+------------+---------+------------------------------------------------------------+--------------+------+------------+
| Engine | Support | Comment | Transactions | XA | Savepoints |
+------------+---------+------------------------------------------------------------+--------------+------+------------+
| MRG_MYISAM | YES | Collection of identical MyISAM tables | NO | NO | NO |
| CSV | YES | CSV storage engine | NO | NO | NO |
| MyISAM | DEFAULT | Default engine as of MySQL 3.23 with great performance | NO | NO | NO |
| InnoDB | YES | Supports transactions, row-level locking, and foreign keys | YES | YES | YES |
| MEMORY | YES | Hash based, stored in memory, useful for temporary tables | NO | NO | NO |
+------------+---------+------------------------------------------------------------+--------------+------+------------
```

##### 查看当前MySQL的默认数据引擎

```
show variables like '%engine%';
mysql> show variables like '%engine%';
+---------------------------+--------+
| Variable_name | Value |
+---------------------------+--------+
| engine_condition_pushdown | ON |
| storage_engine | MyISAM |
+---------------------------+--------+
2 rows in set (0.00 sec)
```

##### 查看和修改最大连接数

使用MySQL 数据库的站点，当访问连接数过多时，就会出现 "Too many connections" 的错误。
出现这种错误有两种情况，一种是网站访问量实在太大，服务器已经负担不起，此时就应该考虑负载均衡或者其它减少服务器压力的办法。另一种情况就是 MySQL 的最大连接数设置得太小，当访问量稍大就出现连接过多的错误。

show variables like '%max\_connections%';
要对 mysql 的最大连接数进行修改，只需要在 my.cnf 配置文件里面修改 max\_connections 的值，然后重启 mysql 就行。
如果 my.ini 文件中没有找到 max\_connections 条目，可自行添加以下条目。

max\_connections = 220
或是
mysql>set global max\_user\_connections = 200; [仅本次修改有效]

实时查看mysql当前连接数
前提：对用户和远程主机有授权

```
mysql> grant all on *.* to root@192.168.9.9 identified by 'your_password';
Query OK, 0 rows affected (0.00 sec)

mysql> flush privileges;
Query OK, 0 rows affected (0.00 sec)

[root@OceanV ~]# mysqladmin -uroot -p -h192.168.9.9 processlist
Enter password:
+----+------+-------------------+----+---------+------+-------+------------------+
| Id | User | Host | db | Command | Time | State | Info |
+----+------+-------------------+----+---------+------+-------+------------------+
| 41 | root | localhost | | Sleep | 13 | | |
| 56 | root | 192.168.9.9:45422 | | Query | 0 | | show processlist |
+----+------+-------------------+----+---------+------+-------+------------------+
```

只查看当前连接数(Threads就是连接数）

```
# mysqladmin -uroot -pyour_password status
Uptime: 4449 Threads: 2 Questions: 18697 Slow queries: 0 Opens: 77 Flush tables: 1 Open tables: 31 Queries per second avg: 4.202

mysql> show full processlist;
+----+------+-----------+-------+---------+------+-------+-----------------------+
| Id | User | Host | db | Command | Time | State | Info |
+----+------+-----------+-------+---------+------+-------+-----------------------+
| 41 | root | localhost | NULL | Query | 0 | NULL | show full processlist |
| 65 | root | localhost | cacti | Sleep | 4 | | NULL |
| 68 | root | localhost | NULL | Sleep | 27 | | NULL |
+----+------+-----------+-------+---------+------+-------+-----------------------+
3 rows in set (0.00 sec)
```

看一下所有连接进程，注意查看进程等待时间以及所处状态 是否locked
如果进程过多，就把进程打印下来，然后查看.
mysql -e 'show full processlist;' -p > 111
查找非locked的进程，一般就是当前执行中卡死，导致后面的进程排队的原因。

查看MySQL连接数和当前用户Mysql连接数
先用管理员身份进入mysql提示符。
mysql -uroot -pxxxx
mysql >show processlist; #可以显示前100条连接信息
show full processlist; #可以显示全部。随便说下，如果用普通账号登录，就只显示这用户的。

##### 修改MySQL监听端口

1.如果你安装的是系统自带的rpm包的情况：
修改 /etc/my.cnf

```
[mysqld]
datadir=/var/lib/mysql
port=3300 #修改成你自己想要的端口
socket=/var/lib/mysql/mysql.sock
[mysql.server]
user=mysql
basedir=/var/lib
[safe_mysqld]
err-log=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid
```

保存退出。
2.如果你安装的是其他源码包或者在同一服务器上安装多个mysqld服务的情况：
同样的配置，找出my.cnf 文件。添加port= 端口号
需要注意的是
[client]
port = 3300
这里也要改一下。

在同一台机器上配置两个MySQL服务（跑两个端口）
cd /usr/local/; cp -r mysql mysql\_2; cd mysql\_2;
初始化mysql2: ./scripts/mysql\_install\_db --user=mysql --datadir=/data/mysql2
拷贝配置文件：cp /etc/my.cnf ./my.cnf
修改配置文件相关参数：vim my.cnf #更改port 以及 socket
启动：/usr/local/mysql\_2/bin/mysqld\_safe --defaults-file=/usr/local/mysql\_2/my.cnf --user=mysql &
若开机启动它，需加入到 /etc/rc.local中

##### 查看mysql设置参数

$mysqladmin -u root -p variables;

##### 查询参数

1) \g 在语句尾，同;
2) \G 在语句尾，使查询结果以竖形输出
3) \c 在语句尾，使当前语句不执行

清屏
\! clear

切换mysql命令结尾符
dlimeter 特殊符;

##### 查看当前版本和当前日期

此命令要求mysql服务器告诉你它的版本号和当前日期

```
mysql select version(),current_date();
+-------------------------------+----------------+
| version() | current_date() |
+-------------------------------+----------------+
| 4.1.7Boco_DC_Group_2004-11-24 | 2008-06-18 |
+-------------------------------+----------------+
1 row in set (0.00 sec)
```

##### 当前是哪个用户

select user();

##### 查看mysql状态

show status;

show global status;

##### 修改mysql参数

```
show variables like 'max_connect%';
set global max_connect_errors = 1000;
```

##### 查看mysql队列

```
show processlist;
```

##### 开启/关闭服务器

$/etc/rc.d/init.d/mysqld start
或
$mysqld\_safe --user=mysql &
停止服务器
$/etc/rc.d/init.d/mysqld stop
或
$mysqladmin shutdown -u root -p
或
/usr/bin/mysqladmin -u root -p shutdown

##### 新用户授权

mysqlgrant all on dbname.\* to username@ identified by 'localhostpassword'
刷新权限表

mysqlflush privileges;

##### 优化表

mysqloptimize table tblA,tblB;
或 [进行优化并检查修复任务]
$mysqlcheck -o dbname tblA tblB tblC -u root -p

##### 对表进行分析

```
mysqlanalyze table tblA;
或
$mysqlcheck -a dbname [tblA tblB tblC ] -u root -p
```

##### 对表进行检查

mysqlcheck table tblA,tblB,tblC;

##### 连接服务器

mysql -u username
-h ipaddress
[-D dbname]
[-P 3306]
[--protocol=name] The protocol of connection (tcp,socket,pipe,memory)
[-S, --socket=name] 连接所用的套接字文件
[--character-sets-dir=name] 字符集所位于的目录
[--default-character-set=name] 默认的字符集
[-E, --vertical] 垂直地打列出查询输出

从命令行登录MySQL数据库服务器
1.登录使用默认3306端口的MySQL
/usr/local/mysql/bin/mysql -u root -p

2.通过TCP连接管理不同端口的多个MySQL（注意：MySQL4.1以上版本才有此项功能）
/usr/local/mysql/bin/mysql -u root -p --protocol=tcp --host=localhost --port=3307

3.通过socket套接字管理不同端口的多个MySQL
/usr/local/mysql/bin/mysql -u root -p --socket=/tmp/mysql3307.sock

4.通过端口和IP管理不同端口的多个MySQL
/usr/local/mysql/bin/mysql -u root -p -P 3306 -h 127.0.0.1

退出mysql命令：
exit（回车） 提示“bye”

##### 修改登录密码

MySQL默认没有密码，安装完毕增加密码的重要性是不言而喻的。
usr/bin/mysqladmin -u root password 'new-password'
格式：mysqladmin -u用户名 -p旧密码 password 新密码

##### 数据库基本管理

创建数据库
Mysql>create database dbname;

显示数据库列表
mysql>show databases;

显示数据表列表
mysql>show tables;

显示数据表的结构
describe 表名;
或
desc tablesname;

显示表的创建信息
show create table tablesname;

创建名称为ocean的数据库
CREATE DATABASE ocean;
DROP tables tablesname;

将表中记录清空
delete from tablesname;

建表
use 库名；create table 表名(字段设定列表)；

删除名称为ocean的数据库
DROP DATABASE ocean;

选择ocean数据库
USE ocean;

(USE 和 QUIT 命令不需要分号结束。）

常用sql命令
查询 select count(\*) from mysql.user; select \* from mysql.db; select \* from mysql.db where host like '10.0.%';
插入 update db1.t1 set name='aaa' where id=1;
清空表 truncate table db1.t1;
删除表 drop table db1.t1;
删除数据库 drop database db1;
修复表 repair table tb1 [use frm];

表操作SQL语句
1、显示当前数据库中存在什么表
SHOW TABLES;

2、创建数据库表zhangyan
在mysql后粘贴以下SQL语句，存储引擎为MYISAM，字段id为主键、唯一索引
。
CREATE TABLE `zhangyan` ( `id` INT( 5 ) UNSIGNED NOT NULL AUTO\_INCREMENT , `username` VARCHAR( 20 ) NOT NULL , `password` CHAR( 32 ) NOT NULL , `time` DATETIME NOT NULL , `number` FLOAT( 10 ) NOT NULL , `content` TEXT NOT NULL , PRIMARY KEY ( `id` ) ) ENGINE = MYISAM ;

3、查看zhangyan表结构
DESCRIBE zhangyan;

4、从表中检索信息
4.1、从zhangyan表中检索所有记录
SELECT \* FROM zhangyan;

4.2、从zhangyan表中检索特定的行：字段username等于abc，字段number等于1，按字段id降序排列
SELECT \* FROM zhangyan WHERE username = abc AND number=1 ORDER BY id DESC;

4.3、从zhangyan表中检索指定的字段：username和password
SELECT username, password FROM zhangyan;

4.4、从zhangyan表中检索出唯一的不重复记录
SELECT DISTINCT username FROM zhangyan;

5、插入信息到zhangyan表
INSERT INTO zhangyan (id, username, password, time, number, content) VALUES (, abc, 123456,
2007-08-06 14:32:12, 23.41, hello world);

6、更新zhangyan表中的指定信息
UPDATE zhangyan SET content = hello china WHERE username = abc;

7、删除zhangyan表中的指定信息
DELETE FROM zhangyan WHERE id = 1;

8、清空zhangyan表
DELETE FROM zhangyan;

9、删除zhangyan表
DROP TABLE zhangyan;

10、更改表结构，将zhangyan表username字段的字段类型改为CHAR(25)
ALTER TABLE zhangyan CHANGE username username CHAR(25);

11、将当前目录下的mysql.sql导入数据库
SOURCE ./mysql.sql;

12、MySQL中将字符串aaa批量替换为bbb的SQL语句
UPDATE表名SET字段名=REPLACE(字段名,aaa,bbb);

13、修复损坏的表
用root帐号从命令行登录MySQL：
mysql-uroot-p
选定数据库名（本例中的数据库名为student）：use student;
修复损坏的表（本例中要修复的表为smis\_user\_student）：　　repair tables mis\_user\_student;udent;

一个建库和建表以及插入数据的实例
drop database if exists school; //如果存在SCHOOL则删除
create database school; //建立库SCHOOL
use school; //打开库SCHOOL
create table subject //建立表
(
id int(3) auto\_increment not null primary key,
name char(10) not null
); //建表结束
//以下为插入字段
insert into subject(name) values('语文');
insert into subject(name) values('数学');
insert into subject(name) values('英语');

create table student //建立表
(
id int(4) auto\_increment not null primary key;
no char(4) not null,
name char(10) not null,
); //建表结束
//以下为插入字段
insert into student(no,name) values('0001','张三');
insert into student(no,name) values('0002','李四');

create table grade //建立表
(
student\_no char(4) not null,
subject\_id int(3) not null,
score int(3) not null default 0 null,
primary key(student\_no,subject\_id);
); //建表结束
我们这里建立的grade表student\_no参考student的no字段，subject\_id参考subject的id字段 它们存在约束关系，
我们给grade表添加两个外键：
subject\_id字段：
alter table grade add foreign key(subject\_id) refrences subject(id) on delete cascade on update cascade;
student\_no字段：
alter table grade add foreign key(student\_no) refrences student(no) on delete cascade on update cascade;
这个时候会报错，因为我们没有把student表中的no设为索引，前一句没有问题是因为subject的id是主键，已经是索引了
我们给student的no添加索引
alter table student add index(no);
然后我们再
alter table grade add foreign key(student\_no) refrences student(no);
这样就OK了

其他一些操作：
添加主键： alter table 表名 add primary key(列名)
删除主键： alter table 表名 drop primary key;
给某列改名： alter table 表名 change 列名 属性列表 比如alter table student change id no char(4)
添加某列：
1 在表的最前面添加列 比如给student表添加id属性 放在表的最前面
alter table student add id int(4) not null auto\_increment primary key first;
2 在表的某个列后加列 比如给student表添加id属性 放在列no的最前面
alter table student add a int(11) afer no;
删除某列： alter table 表名 drop column 列名;
更改某列属性 比如修改student no字段属性 alter table student modify no char(4);
添加索引：alter table 表名 add index 列名
删除索引：alter table 表名 drop index 列名
删除外键：alter table 表名 drop foreign key 约束名
limit的使用：
select \* from 表名 limit 2;//如果只给定一个参数，它表示返回最大的记录行数目
select \* from 表名 limit 1,3;// 第一个参数指定第一个返回记录行的偏移量，第二个参数指定返回记录行的最大数目

##### 更改MySQL目录

MySQL默认的数据文件存储目录为/var/lib/mysql。假如要把目录移到/home/data下需要进行下面几步：
1、home
目录下建立data目录
cd /home
mkdir data
2、把MySQL服务进程停掉：
mysqladmin -u root -p shutdown
3、把/var/lib/mysql整个目录移到/home/data
mv /var/lib/mysql　/home/data/
这样就把MySQL的数据文件移动到了/home/data/mysql下
4、找到my.cnf配置文件
如果/etc/目录下没有my.cnf配置文件，请到/usr/share/mysql/下找到\*.cnf文件，拷贝其中一个到/etc/并改名为my.cnf)中。命令如下：
[root@test1 mysql]# cp /usr/share/mysql/my-medium.cnf　/etc/my.cnf
5、编辑MySQL的配置文件/etc/my.cnf
为保证MySQL能够正常工作，需要指明mysql.sock文件的产生位置。 修改socket=/var/lib/mysql/mysql.sock一行中等号右边的值为：/home/mysql/mysql.sock 。
操作如下：
vi　 my.cnf
# The MySQL server
[mysqld]
port　　　= 3306
#socket　 = /var/lib/mysql/mysql.sock（原内容，为了更稳妥用#注释此行）
socket　 = /home/data/mysql/mysql.sock　　　（加上此行）
6、修改MySQL启动脚本/etc/rc.d/init.d/mysql
最后,需要修改MySQL启动脚本/etc/rc.d/init.d/mysql，把其中datadir=/var/lib/mysql一行中，等号右边的路径改成你现在的实际存放路径：home/data/mysql。
[root@test1 etc]# vi　/etc/rc.d/init.d/mysql
#datadir=/var/lib/mysql　　　　（注释此行）
datadir=/home/data/mysql　　 （加上此行）
7、重新启动MySQL服务
/etc/rc.d/init.d/mysql　start
如果工作正常移动就成功了，否则对照前面的7步再检查一下。

##### 查看表的最后mysql修改时间

select TABLE\_NAME,UPDATE\_TIME from INFORMATION\_SCHEMA.tables where TABLE\_SCHEMA='数据库名';
可以通过查看数据库中表的mysql修改时间，来确定mysql数据库是否已经长期不再使用。

##### 查看表的创建时间

select TABLE\_NAME,CREATE\_TIME from information\_schema.TABLES where TABLE\_SCHEMA='数据库名' and information\_schema.TABLES.TABLE\_NAME = '表名';

##### 查看数据大小

如果想知道MySQL数据库中每个表占用的空间、表记录的行数的话，可以打开MySQL的 information\_schema 数据库。在该库中有一个 TABLES 表，这个表主要字段分别是：
TABLE\_SCHEMA : 数据库名
TABLE\_NAME：表名
ENGINE：所使用的存储引擎
TABLES\_ROWS：记录数
DATA\_LENGTH：数据大小
INDEX\_LENGTH：索引大小

其他字段请参考MySQL的手册，我们只需要了解这几个就足够了。
所以要知道一个表占用空间的大小，那就相当于是 数据大小 + 索引大小 即可。

SQL:
SELECT TABLE\_NAME,DATA\_LENGTH+INDEX\_LENGTH,TABLE\_ROWS FROM TABLES WHERE TABLE\_SCHEMA='数据库名' AND TABLE\_NAME='表名'

**1、进去指定schema 数据库（存放了其他的数据库的信息）**
mysql> use information\_schema;
Database changed
**2、查询所有数据的大小**
mysql> select concat(round(sum(DATA\_LENGTH/1024/1024), 2), 'MB')
-> as data from TABLES;
+-----------+
| data      |
+-----------+
| 6674.48MB |
+-----------+
1 row in set (16.81 sec)

##### 查看指定数据库实例的大小，比如说数据库 forexpert

mysql> select concat(round(sum(DATA\_LENGTH/1024/1024), 2), 'MB')
-> as data from TABLES where table\_schema='forexpert';
+-----------+
| data      |
+-----------+
| 6542.30MB |
+-----------+
1 row in set (7.47 sec)
concat和“MB”是单位
round和2表明精确2位小数
sum表明所有的索引相加
table\_schema='forexpert'就是你要统计的数据库

##### 查看指定数据库的表的大小，比如说数据库 forexpert 中的 member 表

mysql> select concat(round(sum(DATA\_LENGTH/1024/1024),2),'MB') as data
-> from TABLES where table\_schema='forexpert'
-> and table\_name='member';
+--------+
| data   |
+--------+
| 2.52MB |
+--------+
1 row in set (1.88 sec)

##### 如何使用mysql 命令行 查看mysql数据库大小、表大小、数据大小、索引大小

select \* from information\_schema.TABLES
where information\_schema.TABLES.TABLE\_SCHEMA='databasename'
and information\_schema.TABLES.TABLE\_NAME='tablename'\G

##### mysql使用普通用户备份

# mysqldump -u dbuser -ppass db > db.sql
#mysqldump: Got error: 1044: Access denied for user 'dbuser'@'localhost' to database 'db' when using LOCK TABLES

解决一：
加上-skip-lock-tables选项即可。即：
# mysqldump -u dbuser -ppass db --skip-lock-tables > db.sql

解决2：
使用具有lock权限的用户进行备份。
grant select,reload,lock tables on \*.\* to `xx`@`xx`;

#####

##### SHOW STATUS  与 SHOW GLOBAL STATUS 的区别

前者是基于某个连接会话级别的计数器
或者是服务器级别的全局计数器

```
mysql> show status like "%warning%";
+-------------------+-------+
| Variable_name     | Value |
+-------------------+-------+
| Com_show_warnings | 2     |
+-------------------+-------+
1 row in set (0.01 sec)

mysql> flush status;
Query OK, 0 rows affected (0.00 sec)

mysql> show status like "%warning%";
+-------------------+-------+
| Variable_name     | Value |
+-------------------+-------+
| Com_show_warnings | 0     |
+-------------------+-------+
1 row in set (0.00 sec)

mysql>
mysql> show global status like "%warning%";
+-------------------+-------+
| Variable_name     | Value |
+-------------------+-------+
| Com_show_warnings | 2     |
+-------------------+-------+
1 row in set (0.00 sec)
```

##### 查看 Mysql 读取的是哪一个配置文件

```
$sudo mysqld --verbose --help | grep -A 1 'Default options'
Default options are read from the following files in the given order:
/etc/my.cnf /etc/mysql/my.cnf ~/.my.cnf
```
