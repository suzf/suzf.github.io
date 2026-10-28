---
title: "Windows上传文件到Linux文件名称乱码解决"
slug: "windows上传文件到linux文件名称乱码解决"
date: 2015-11-16T15:34:00+08:00
author: "Jeffrey Su"
description: "众所周知， Windows 和 Linux 系统所使用的编码格式是不同的；Winddows 默认编码是GB2312,而Linux系统默认编码是UTF-8。如果想将Windows的文件移动到Linux系统后，文件名称不发生乱码，这时候该怎么办…"
categories: ["技能矩阵"]
tags: ["linux"]
---

众所周知， Windows 和 Linux 系统所使用的编码格式是不同的；Winddows 默认编码是GB2312,而Linux系统默认编码是UTF-8。如果想将Windows的文件移动到Linux系统后，文件名称不发生乱码，这时候该怎么办呢？

要想正确显示，要么修改Linux系统编码为GB2312，要么修改文件名编码（文件内容不修改）。显然第一种方式不太可取，那么我们就将文件名称的编码格式转换成UTF-8。

Linux 中有这么一个工具 convmv - converts filenames from one encoding to another

安装方式

```
 # Centos
 yum -y install convmv

 # Debian
 apt-get install convmv
```

语法及主要参数

```
convmv [options] FILE(S) … DIRECTORY(S)
主要选项：
-f ENCODING  指定目前文件名的编码，如-f gbk, gb2312
-t ENCODING  指定将要转换成的编码，如-t utf-8
-r           递归转换目录下所有文件名
–list        列出所有支持的编码
–notest      默认是只打印转换后的效果，加这个选项才真正执行转换操作。
更多选项请 man convmv。
```

实例

```
# 递归转换一个目录下所有文件名称
@_@[15:19:44][007@happycode notes]$convmv -f gb2312 -t UTF-8 --notest -r  TXT
mv "TXT/Sublime/Package Controlʨ׃´	"TXT/Sublime/Package Control设置代理"
mv "TXT/Sublime/°²װPackage control"	"TXT/Sublime/安装Package control"
mv "TXT/A_Linux/Tcpdump/tcpdump ļ®µŊ¹ԃ"	"TXT/A_Linux/Tcpdump/tcpdump 命令的使用"
mv "TXT/A_Linux/Others/Dell·þϱǷ¹̼þʽ¼¶"	"TXT/A_Linux/Others/Dell服务器固件升级"
mv "TXT/A_Linux/Others/ʨ±¸א¶ϰ?½͘¶¨CPU(SMP IRQ Affinity)"	"TXT/A_Linux/Others/设备中断绑定到特定CPU(SMP IRQ Affinity)"
mv "TXT/A_Linux/Others/Ubuntu LinuxϵͳЂapt-getļ®Ъ½	"TXT/A_Linux/Others/Ubuntu Linux系统下apt-get命令详解"
mv "TXT/A_Linux/Others/nano τ±¾±༭Ƿ"	"TXT/A_Linux/Others/nano 文本编辑器"
mv "TXT/A_Linux/Others/º̐Ŏļþ"	"TXT/A_Linux/Others/核心文件"
mv "TXT/A_Linux/Others/ԅ»¯"	"TXT/A_Linux/Others/优化"
mv "TXT/A_Linux/Image/Linux Ђ¸?ƺ¼ԋ®ӡ"	"TXT/A_Linux/Image/Linux 下给图片批量加水印"
mv "TXT/A_Linux/LVM/½«һ¸?꓆¶¯µ½­һ¸?³"	"TXT/A_Linux/LVM/将一个卷组移动到另一个系统"
mv "TXT/A_Linux/LVM/Linux rescueģʽЂ˖¶¯¹Ӕ׌VM·ׇ	"TXT/A_Linux/LVM/Linux rescue模式下手动挂载LVM分区"
...
...
mv "TXT/Web/Apache/θվО̙"	"TXT/Web/Apache/网站限速"
mv "TXT/Web/Nginx/nginx ldap ɏ֤"	"TXT/Web/Nginx/nginx ldap 认证"
Ready! I converted 165 files in 1 seconds.
```

Man page: [man-1-convmv](https://linux.die.net/man/1/convmv)
