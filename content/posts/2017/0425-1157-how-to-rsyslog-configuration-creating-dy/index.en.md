---
title: "Rsyslog: Write Each Program's Logs to Its Own File"
slug: "how-to-rsyslog-configuration-creating-dynamic-file-names-based-on-program-name"
date: 2017-04-25T11:57:17+08:00
author: "Jeffrey Su"
description: "Use an rsyslog template with %programname% so each program's messages land in their own log file, with filters for which programs to split out and a logger test."
categories: ["Skills Matrix"]
tags: ["rsyslog", "Log", "linux"]
---

I wanted rsyslog, the logging daemon that ships with RHEL/CentOS, to write each program's messages to a file named after that program.

<!--more-->

> *A word of caution: this is not a secure setup. Any process can claim to be any program name when it logs through rsyslog. It is still a handy way to keep the logs of several applications apart.*

First, create a template for the dynamic file name:

```text
# cat /etc/rsyslog.d/dynamic_file.conf
# Create dynamic file template
template (name="Dyn_File" type="string" string="/var/log/app/%programname%.log")
```

Then use the template. Here are two example rules:

```text
# grep conditions -A 9 /etc/rsyslog.d/dynamic_file.conf
# Add conditions; if match, rewrite it to /var/log/app/%programname%.log"
if $syslogfacility-text == 'local6' and $programname startswith 'test' then ?Dyn_File
& ~

if $programname == 'blue' then ?Dyn_File
& ~
# The closing & ~ are closing tags to stop processing of further rules.
```

Create the log directory and restart rsyslog:

```text
# mkdir /var/log/app
# systemctl restart rsyslog.service
```

Finally, test it with `logger`:

```text
# logger  -t blue -p local6.notice "Test Creating Dynamic File Names Based On Program Name"
# logger  -t test_dynfile -p local6.notice "Test Creating Dynamic File Names Based On Program Name"
```

Each program got its own file:

```text
# grep -ir "Dynamic File" /var/log/app/
/var/log/app/blue.log:2017-04-25T11:43:19.243175+08:00 monkey blue: Test Creating Dynamic File Names Based On Program Name
/var/log/app/test_dynfile.log:2017-04-25T11:44:21.988681+08:00 monkey test_dynfile: Test Creating Dynamic File Names Based On Program Name
```

For more filter options, see the [rsyslog v8 filter documentation](http://www.rsyslog.com/doc/v8-stable/configuration/filters.html).

References

[0] http://www.rsyslog.com/doc/v8-stable/configuration/templates.html

[1] http://www.rsyslog.com/doc/v8-stable/configuration/filters.html
