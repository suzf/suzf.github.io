---
title: "How-to Rsyslog Configuration Creating Dynamic File Names Based On Program Name"
slug: "how-to-rsyslog-configuration-creating-dynamic-file-names-based-on-program-name"
date: 2017-04-25T11:57:17+08:00
author: "Jeffrey Su"
description: "前言 我想使用 RHEL/CentOS 系统自带的日志工具Rsyslog, 根据程序日志类别动态存储到一个以程序名命名的文件。"
categories: ["技能矩阵"]
tags: ["rsyslog", "Log", "linux"]
---

前言 我想使用 RHEL/CentOS 系统自带的日志工具Rsyslog, 根据程序日志类别动态存储到一个以程序名命名的文件。

<!--more-->

> *温馨提示： 这不是一个安全的配置，任何人都可以假装是在系统中使用rsyslog 的程序。但是，这也可以对多个程序日志起到一个很好的分隔的 作用。*

首先我们应该创建一个动态文件名字的模板

```text
# cat /etc/rsyslog.d/dynamic_file.conf
# Create dynamic file template
template (name="Dyn_File" type="string" string="/var/log/app/%programname%.log")
```

接着我们可以使用上面创建的模板了，下面我们来添加两个测试的例子

```text
# grep conditions -A 9 /etc/rsyslog.d/dynamic_file.conf
# Add conditions; if match, rewrite it to /var/log/app/%programname%.log"
if $syslogfacility-text == 'local6' and $programname startswith 'test' then ?Dyn_File
& ~

if $programname == 'blue' then ?Dyn_File
& ~
# The closing & ~ are closing tags to stop processing of further rules.
```

之后创建日志目录， 重载程序

```text
# mkdir /var/log/app
# systemctl restart rsyslog.service
```

最后我们使用 `logger` 工具进行测试

```text
# logger  -t blue -p local6.notice "Test Creating Dynamic File Names Based On Program Name"
# logger  -t test_dynfile -p local6.notice "Test Creating Dynamic File Names Based On Program Name"
```

Bingo

```text
# grep -ir "Dynamic File" /var/log/app/
/var/log/app/blue.log:2017-04-25T11:43:19.243175+08:00 monkey blue: Test Creating Dynamic File Names Based On Program Name
/var/log/app/test_dynfile.log:2017-04-25T11:44:21.988681+08:00 monkey test_dynfile: Test Creating Dynamic File Names Based On Program Name
```

更多的 Filter 详见  [rsylog v8 filter documentation](http://www.rsyslog.com/doc/v8-stable/configuration/filters.html).

Reference

[0] http://www.rsyslog.com/doc/v8-stable/configuration/templates.html

[1] http://www.rsyslog.com/doc/v8-stable/configuration/filters.html
