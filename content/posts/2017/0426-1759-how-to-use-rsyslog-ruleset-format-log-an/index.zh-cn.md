---
title: "How-to use rsyslog parse log to json format and then store in ES"
slug: "how-to-use-rsyslog-ruleset-format-log-and-then-store-on-es"
date: 2017-04-26T17:59:21+08:00
author: "Jeffrey Su"
description: "前言 本文的主要目的是将 Apache 的访问日志转换成 JSON 格式，然后存储到 ES, 供 ELK Stack Platform 进行数据分析与统计。 尽管现在许多发行版本都已经默认安装上了 rsyslog, 但是还是推荐从 rsys…"
categories: ["技能矩阵"]
tags: ["Apache", "rsyslog", "elasticsearch", "ELK", "linux"]
---

## 前言

本文的主要目的是将 Apache 的访问日志转换成 JSON 格式，然后存储到 ES, 供 ELK Stack Platform 进行数据分析与统计。 尽管现在许多发行版本都已经默认安装上了 rsyslog, 但是还是推荐从 [rsyslog repositories](http://www.rsyslog.com/downloads/download-other/) 获取最新的稳定版本。这样你将从中获益。你将需要下面的软件包：

- rsyslog-mmnormalize. This gives you [mmnormalize](http://www.rsyslog.com/doc/master/configuration/modules/mmnormalize.html), a module that will do the parsing of common Apache logs to JSON
- rsyslog-elasticsearch, for the [Elasticsearch output](http://www.rsyslog.com/doc/master/configuration/modules/omelasticsearch.html)

让我现在就开始配置吧。需要执行以下操作：

1. 加载所需模块
2. 将 Apache log 传送到中心日志服务器
3. 配置主队列缓冲您的消息。 这也是定义工作线程数和批量大小的地方（也可以是 Elasticsearch 块的大小）
4. 将 Apache log 转换成 JSON
5. 定义一个模板，您可以在其中指定 JSON 信息的格式。 您可以使用此模板通过Elasticsearch输出将日志发送到 Elasticsearch / Logstash

<!--more-->

### 加载所需模块

```text
# The imjournal module bellow is now used as a message source instead of imuxsock.
$ModLoad imuxsock  # provides support for local system logging (e.g. via logger command)
$ModLoad imjournal # provides access to the systemd journal
$ModLoad imklog    # reads kernel messages (the same are read from journald)
$ModLoad immark    # provides --MARK-- message capability

# Provides UDP syslog reception
$ModLoad imudp
$UDPServerRun 514

# Provides File syslog reception
# $ModLoad imfile

# Provides parser syslog reception
$ModLoad mmnormalize

# Elasticsearch output module
$ModLoad omelasticsearch
```

### 日志输入配置

```text
cat >> /etc/rsyslog.conf << EOF
# Send all log to logserver
*.* @log.suzf.net:514
EOF
```

之后 重启 rsyslog PS: 将 Apache access log 发送到中心日志服务器。当然，也可是使用Rsyslog imfile 模块将日志传送过去，具体过程，略。

### Queue and workers

默认，所有进来的信息都会到达 main queue. 你可以指定一个，你可以使用 [rulesets](http://www.rsyslog.com/doc/master/concepts/multi_ruleset.html) 根据类别指定多个。但是让我们使他简单一些吧。

```text
main_queue(
  queue.workerThreads="4"
  queue.dequeueBatchSize="1000"
  queue.highWatermark="500000"    # max no. of events to hold in memory
  queue.lowWatermark="200000"     # use memory queue again, when it's back to this level
  queue.spoolDirectory="/var/run/rsyslog/queues"  # where to write on disk
  queue.fileName="stats_ruleset"
  queue.maxDiskSpace="5g"        # it will stop at this much disk space
  queue.size="5000000"           # or this many messages
  queue.saveOnShutdown="on"      # save memory queue contents to disk when rsyslog is exiting
)
```

### 使用 mmnormalize 格式化数据

mmnormalize 模块使用 [liblognorm](https://github.com/rsyslog/liblognorm/blob/master/doc/introduction.rst) 进行解析。所以在配置中你只需简单的指定 rsyslog 的liblognorm rulebase：

```text
action(type="mmnormalize" 
    ruleBase="/etc/rsyslog.d/apache_access_log.rule")
```

apache\_access\_log.rule 文件包含了解析 Apache log 的规则；如下。具体的规则取决于你Apache log 预先定义的格式。

```text
# cat /etc/rsyslog.d/apache_access_log.rule
version=2
# prefix=%rcvdat:date-rfc5424% %rcvdfrom:word% %tag:word%
rule=:%clientip:word% %delay:word% %identd:word% %auth:word% [%accesstime:char-to:]%] "%method:word% %request:word% %pversion:char-to:"%" %status:word% %bytesend:word% %referer:word% %useragent:quoted-string%
```

更多的配置规则详见 [liblognorm documentation](https://github.com/rsyslog/liblognorm/blob/master/doc/configuration.rst). 创建一个新的规则不是一气呵成的， 检查你的规则有没有错误, 你可以使用向这样使用 **lognormalizer <`yum install -y liblognorm-utils`>** :

```text
head -1 /path/to/log.file | /usr/lib/lognorm/lognormalizer -r /path/to/rulebase.rb -e json
```

举个栗子

```text
# cat test_msg
172.16.9.1 241 - - [26/Apr/2017:11:31:48 +0800] "GET /images/apache_pb.gif HTTP/1.1" 304 - "-" "Mozilla/5.0 (Windows NT 10.0; WOW64; rv:53.0) Gecko/20100101 Firefox/53.0"
# head -1 test_msg | lognormalizer  -r /etc/rsyslog.d/apache_access_log.rule -e json
{"useragent": "Mozilla/5.0 (Windows NT 10.0; WOW64; rv:53.0) Gecko/20100101 Firefox/53.0", "referer": "\"-\"", "bytes": "-", "status": "304", "pversion": "HTTP/1.1", "request": "/images/apache_pb.gif", "method": "GET", "accesstime": "26/Apr/2017:11:31:48 +0800", "auth": "-", "identd": "-", "delay": "241", "clientip": "172.16.9.1"}
```

注： 默认未解析的数据会出现在 ·`unparsed-data`

### Time-based indices in your own Elasticsearch cluster

```text
# this is for index names to be like: apache-access-log-YYYY.MM.DD
template(name="apache-access-log-index" type="list") {
    constant(value="apache-access-log-")
    property(name="timereported" dateFormat="rfc3339" position.from="1" position.to="4")
    constant(value=".")
    property(name="timereported" dateFormat="rfc3339" position.from="6" position.to="7")
    constant(value=".")
    property(name="timereported" dateFormat="rfc3339" position.from="9" position.to="10")
}
```

### Templates

```text
template(name="WebFiles" type="string" string="/var/log/web/httpd/access_%$!vhost%.log")
template(name="apache-access-log" type="list" option.json="on") {
        constant(value="{")
        constant(value="\"@version\":\"0.0.1\", ")
        constant(value="\"@timestamp\":\"")             property(name="timereported" dateFormat="rfc3339")
        constant(value="\",\"message\":\"")             property(name="msg" position.from="1" spifno1stsp="off")
        constant(value="\",\"host\":\"")                property(name="fromhost-ip")
        constant(value="\",\"@source_host\":\"")        property(name="hostname")
        constant(value="\",\"tag\":\"")                 property(name="syslogtag")
        constant(value="\",\"clientip\":\"")            property(name="$!clientip")
        constant(value="\",\"delay\":\"")               property(name="$!delay")
        constant(value="\",\"identd\":\"")              property(name="$!identd")
        constant(value="\",\"auth\":\"")                property(name="$!auth")
        constant(value="\",\"accesstime\":\"")         property(name="$!accesstime")
        constant(value="\",\"method\":\"")              property(name="$!method")
        constant(value="\",\"request\":\"")             property(name="$!request")
        constant(value="\",\"pversion\":\"")            property(name="$!pversion")
        constant(value="\",\"status\":\"")              property(name="$!status")
        constant(value="\",\"bytes\":\"")               property(name="$!bytes")
        constant(value="\",\"referrer\":\"")            property(name="$!referer")
        constant(value="\",\"useragent\":\"")           property(name="$!useragent")
        constant(value="\"}")
}

# If you’re using rsyslog only for parsing Apache logs (and not system logs)
# and send your logs to Logsene, this bit is rather simple.
# Because by the time parsing ended, you already have all the relevant fields in the $!all-json variable,
# that you’ll use as a template:

template(name="all-json" type="list"){
  property(name="$!all-json")
}
```

### Actions

```text
if $programname == 'access_test' then {
    action(type="mmnormalize" ruleBase="/etc/rsyslog.d/apache_access_log.rule")
    if $parsesuccess == "OK" then {         
              action(type="omfile" DynaFile="WebFiles" template="apache-access-log" DirCreateMode="0755" FileCreateMode="0644")
              action(type="omelasticsearch"
                        server="172.16.9.50"
                        serverport="9200"
                        template="apache-access-log"
                        # template="all-json"
                        searchIndex="apache-access-log-index"
                        dynSearchIndex="on"
                        searchType="events"
                        bulkmode="on"
                        queue.type="linkedlist"
                        queue.size="5000"
                        queue.dequeuebatchsize="300"
                        action.resumeretrycount="-1"
                        errorFile="/var/log/omelasticsearch22.log")
        stop
    }
}
```

上述配置全部截取自 `/etc/rsyslog.conf` 文件中 之后重启 Rsyslog & 看看有没有错误输出 之后在 Kibana 上创建索引。验证：

![rsyslog_parse_2_json_elk](rsyslog_parse_2_json_elk.png)

Reference

[0] http://www.liblognorm.com/files/manual/index.html

[1] http://httpd.apache.org/docs/current/mod/mod\_log\_config.html

[2] http://www.rsyslog.com/rsyslog-and-elasticsearch/

[3] https://linux-help.org/wiki/logging/rsyslog/advanced-rsyslog

[4] http://www.rsyslog.com/log-normalization-for-different-formats/

[5] https://techpunch.co.uk/development/how-to-ship-logs-with-rsyslog-and-logstash

[6] http://www.rsyslog.com/tag/liblognorm/
