---
title: "How to Send Nginx Logs to a Remote Syslog Server"
slug: "how-to-configure-nginx-logging-to-syslog"
date: 2017-04-24T14:16:38+08:00
author: "Jeffrey Su"
description: "Send Nginx access and error logs straight to a central rsyslog server with the syslog: target (Nginx 1.7.1+), or with rsyslog's imfile module on older versions."
categories: ["Skills Matrix"]
tags: ["Nginx", "Log", "syslog", "linux"]
---

### Introduction

Centralized logging has a lot going for it. So how do you get Nginx logs onto a log server? Since version 1.7.1, Nginx can log to syslog directly.

<!--more-->

### Nginx log configuration

```
# diff -ruN /etc/nginx/nginx.conf{.old,}
--- /etc/nginx/nginx.conf.old	2017-04-24 13:45:56.125362028 +0800
+++ /etc/nginx/nginx.conf	2017-04-24 14:04:38.293694706 +0800
@@ -4,7 +4,8 @@
 
 user nginx;
 worker_processes auto;
-error_log /var/log/nginx/error.log;
+# error_log /var/log/nginx/error.log;
+error_log syslog:server=log.suzf.net:514,tag=nginx_error;
 pid /run/nginx.pid;
 
 # Load dynamic modules. See /usr/share/nginx/README.dynamic.
@@ -19,7 +20,8 @@
                       '$status $body_bytes_sent "$http_referer" '
                       '"$http_user_agent" "$http_x_forwarded_for"';

-    access_log  /var/log/nginx/access.log  main;
+    # access_log  /var/log/nginx/access.log  main;
+    access_log  syslog:server=log.suzf.net:514,facility=local6,tag=nginx_access,severity=info main;
 
     sendfile            on;
     tcp_nopush          on;
```

### Remote log server configuration

```
# grep nginx_ /etc/rsyslog.conf
if $syslogfacility-text == 'local6' and $programname == 'nginx_access' then /var/log/nginx/access_test.log
if $syslogfacility-text == 'local6' and $programname == 'nginx_error' then /var/log/nginx/error_test.log
```

### Check on the log server

```
@log.suzf.net ~# head -1 /var/log/nginx/access_test.log
2017-04-24T13:57:22+08:00 horse.suzf.net nginx: 172.16.9.1 - - [24/Apr/2017:13:57:22 +0800] "GET / HTTP/1.1" 200 3700 "-" "Mozilla/5.0 (Windows NT 10.0; WOW64; rv:52.0) Gecko/20100101 Firefox/52.0" "-"
```

### Syslog parameters

These parameters configure logging to syslog (from the [Nginx documentation](http://nginx.org/en/docs/syslog.html)):

`server=address`

Defines the address of a syslog server. The address can be specified as a domain name or IP address, with an optional port, or as a UNIX-domain socket path specified after the “`unix:`” prefix. If port is not specified, the UDP port 514 is used. If a domain name resolves to several IP addresses, the first resolved address is used.

`facility=string`

Sets facility of syslog messages, as defined in [RFC 3164](https://tools.ietf.org/html/rfc3164#section-4.1.1). Facility can be one of “`kern`”, “`user`”, “`mail`”, “`daemon`”, “`auth`”, “`intern`”, “`lpr`”, “`news`”, “`uucp`”, “`clock`”, “`authpriv`”, “`ftp`”, “`ntp`”, “`audit`”, “`alert`”, “`cron`”, “`local0`”..“`local7`”. Default is “`local7`”.

`severity=string`

Sets severity of syslog messages for [access\_log](http://nginx.org/en/docs/http/ngx_http_log_module.html#access_log), as defined in [RFC 3164](https://tools.ietf.org/html/rfc3164#section-4.1.1). Possible values are the same as for the second parameter (level) of the [error\_log](http://nginx.org/en/docs/ngx_core_module.html#error_log) directive. Default is “`info`”.

> Severity of error messages is determined by nginx, thus the parameter is ignored in the `error_log` directive.

`tag=string`

Sets the tag of syslog messages. Default is “`nginx`”.

`nohostname`

Disables adding the “hostname” field into the syslog message header (1.9.7).

### Nginx older than 1.7.1

Leave the Nginx configuration as it is, and use the [rsyslog imfile module](http://www.rsyslog.com/doc/v8-stable/configuration/modules/imfile.html) to turn the log files into rsyslog messages:

```
# cat /etc/rsyslog.d/nginx.conf
# needs to be done just once; suggest add it to /etc/rsyslog.conf
$ModLoad imfile

# nginx access log
$InputFileName /var/log/nginx/access.log
$InputFileTag nginx_access:
$InputFileStateFile stat-nginx-acess

$InputFileSeverity notice
$InputFileFacility local6
$InputRunFileMonitor

# check for new lines every 2 seconds
$InputFilePollInterval 2

# grep log.suzf.net /etc/rsyslog.conf
*.* @log.suzf.net:514
```

The remote log server is configured the same way as above.

References

[0] http://nginx.org/en/docs/syslog.html

[1] https://www.nginx.com/resources/admin-guide/logging-and-monitoring/
