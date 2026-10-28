---
title: "Nginx之Upstream模块实现负载均衡"
slug: "nginx之upstream模块实现负载均衡"
date: 2014-08-18T21:08:02+08:00
author: "Jeffrey Su"
description: "1、轮询（默认） 每个请求按时间顺序逐一分配到不同的后端服务器，如果后端服务器down掉，能自动剔除。 2、weight 指定轮询几率，weight和访问比率成正比，用于后端服务器性能不均的情况。 例如： upstream bakend {…"
categories: ["技能矩阵"]
tags: ["Nginx", "linux"]
---

1、轮询（默认）

每个请求按时间顺序逐一分配到不同的后端服务器，如果后端服务器down掉，能自动剔除。

2、weight
指定轮询几率，weight和访问比率成正比，用于后端服务器性能不均的情况。
例如：
upstream bakend {
server 172.16.7.14 weight=10;
server 172.16.7.15 weight=10;
}

3、ip\_hash
每个请求按访问ip的hash结果分配，这样每个访客固定访问一个后端服务器，可以解决session的问题。
例如：
upstream bakend {
ip\_hash;
server 172.16.7.14:88;
server 172.16.7.15:80;
}

4、fair（第三方）
按后端服务器的响应时间来分配请求，响应时间短的优先分配。
upstream backend {
server server1;
server server2;
fair;
}

5、url\_hash（第三方）

按访问url的hash结果来分配请求，使每个url定向到同一个后端服务器，后端服务器为缓存时比较有效。

例：在upstream中加入hash语句，server语句中不能写入weight等其他的参数，hash\_method是使用的hash算法

upstream backend {
server squid1:3128;
server squid2:3128;
hash $request\_uri;
hash\_method crc32;
}

upstream bakend{#定义负载均衡设备的Ip及设备状态
ip\_hash;
server 127.0.0.1:9090 down;
server 127.0.0.1:8080 weight=2;
server 127.0.0.1:6060;
server 127.0.0.1:7070 backup;
}
在需要使用负载均衡的server中增加
proxy\_pass http://bakend/;

每个设备的状态设置为:
1.down 表示单前的server暂时不参与负载
2.weight 默认为1.weight越大，负载的权重就越大。
3.max\_fails ：允许请求失败的次数默认为1.当超过最大次数时，返回proxy\_next\_upstream 模块定义的错误
4.fail\_timeout:max\_fails次失败后，暂停的时间。
5.backup： 其它所有的非backup机器down或者忙的时候，请求backup机器。所以这台机器压力会最轻。

nginx支持同时设置多组的负载均衡，用来给不用的server来使用。

client\_body\_in\_file\_only 设置为On 可以讲client post过来的数据记录到文件中用来做debug
client\_body\_temp\_path 设置记录文件的目录 可以设置最多3层目录

location 对URL进行匹配.可以进行重定向或者进行新的代理 负载均衡

例：配置使用Nginx实现LB
[root@Jeffery ~]# sed -i '/^[ \t]\*#/d; /^$/d' /usr/local/nginx/conf/nginx.conf
[root@Jeffery ~]# cat /usr/local/nginx/conf/nginx.conf
worker\_processes 1;

events {
worker\_connections 1024;
}

http {
upstream Jeffery\_lb {
ip\_hash; #会话保持
server 172.16.7.30:80; #后端的真实服务器
server 172.16.7.40:80; #后端的真实服务器
server 172.16.7.50:80; #后端的真实服务器
}

server {
listen 80;
server\_name www.Jeffery.com;

location / {
root html;
index index.php index.html index.htm;
proxy\_pass http://Jeffery\_lb;
proxy\_set\_header Host $host;
}

error\_page 500 502 503 504 /50x.html;
location = /50x.html {
root html;
}
}
}
