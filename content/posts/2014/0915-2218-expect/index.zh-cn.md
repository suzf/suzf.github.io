---
title: "Expect自动化控制简单介绍"
slug: "expect自动化控制简单介绍"
date: 2014-09-15T22:18:09+08:00
author: "Jeffrey Su"
description: "telnet，ftp，Passwd，fsck，rlogin，tip，ssh等等。该工具利用Unix伪终端包装其子进程，允许任意程序通过终端接入进行自动化控制；也可利用Tk工具，将交互程序包装在X11的图形用户界面中。 shell脚本需要交互…"
categories: ["技能矩阵"]
tags: ["expect", "linux"]
---

telnet，ftp，Passwd，fsck，rlogin，tip，ssh等等。该工具利用Unix伪终端包装其子进程，允许任意程序通过终端接入进行自动化控制；也可利用Tk工具，将交互程序包装在X11的图形用户界面中。

shell脚本需要交互的地方可以使用here文档是实现，但是有些命令却需要用户手动去就交互如passwd、scp

对自动部署免去用户交互很痛苦，expect能很好的解决这类问题。

expect的核心是spawn expect send set

spawn 调用要执行的命令

expect 等待命令提示信息的出现，也就是捕捉用户输入的提示：

send 发送需要交互的值，替代了用户手动输入内容

set 设置变量值

interact 执行完成后保持交互状态，把控制权交给控制台，这个时候就可以手工操作了。如果没有这一句登录完成后会退出，而不是留在远程终端上。

expect eof 这个一定要加，与spawn对应表示捕获终端输出信息终止，类似于if....endif

expect脚本必须以interact或expect eof结束，执行自动化任务通常expect eof就够了。

设置expect永不超时

```text
set timeout -1
```

设置expect 300秒超时，如果超过300没有expect内容出现，则推出

```text
set timeout 300
```

expect编写语法，expect使用的是tcl语法。

一条Tcl命令由空格分割的单词组成. 其中, 第一个单词是命令名称, 其余的是命令参数

```text
cmd arg arg arg
```

$符号代表变量的值. 在本例中, 变量名称是foo.

```text
$foo
```

方括号执行了一个嵌套命令. 例如, 如果你想传递一个命令的结果作为另外一个命令的参数, 那么你使用这个符号

```text
[cmd arg]
```

双引号把词组标记为命令的一个参数. "$"符号和方括号在双引号内仍被解释

```text
"some stuff"
```

大括号也把词组标记为命令的一个参数. 但是, 其他符号在大括号内不被解释

```text
{some stuff}
```

反斜线符号是用来引用特殊符号. 例如：\n 代表换行. 反斜线符号也被用来关闭"$"符号, 引号,方括号和大括号的特殊含义

### 自动登录运程主机并执行命令

```text
[root@www expect]# cat ssh_log_cmd.expect
#!/usr/bin/expect
set user "root"
set password "jeffery"
set ip "172.16.7.91"

spawn ssh $user@$ip

expect {
"yes/no" {send "yes\r";exp_continue}
"password:" {send "$password\r"}
}
expect "]*"
send "touch /tmp/haha.txt\r"
expect "]*"
send "echo haha > /tmp/haha.txt\r"
expect "]*"
send "exit\r"
```

### 使用rsync同步文件

```text
[root@www expect]# cat sync_file.expect
#!/usr/bin/expect
# Desc: auto sync file
# Author: Jeffery.su
# Date: 15/09/2014

set user "root"
set password "jeffery"
set host "172.16.7.91"

spawn rsync -av $user@$host:/tmp/haha.txt /tmp

expect {
"yes/no" {send "yes\r"}
"password" {send "$password\r"}
}
```

### 参数的使用

```text
[root@www expect]# cat trans_para.expect
#!/usr/bin/expect
# Desc: transmit parameter
# Author: Jeffery.Su
# Date: 15/09/2014

set user [lindex $argv 0]
set host [lindex $argv 1]
set password "jeffery"
set cm [lindex $argv 2]

spawn ssh $user@$host

expect {
"yes/no" {send "yes\r"}
"password" {send "$password\r"}
}

expect "]*"
send "$cm\r"
expect "]*"
send "exit\r"
```

调用：`expect trans_para.expect root 172.16.7.91 date`
