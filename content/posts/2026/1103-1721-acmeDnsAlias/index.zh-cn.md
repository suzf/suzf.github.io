---
title: "acme.sh DNS alias 模式签发 SSL 证书：不把主域名的 DNS 权限交出去"
slug: "acme sh dns alias mode"
date: 2026-11-03T17:21:55+08:00
author: "Jeffrey Su"
description: "DNS alias 模式的原理、CNAME 怎么加、用 acme.sh 签发通配符证书并安装到 Nginx、多域名和多个 DNS 服务商的写法、续期，以及校验失败时该查什么。"
categories: ["技能矩阵"]
tags: ["ssl", "acme", "letsencrypt", "dns"]
toc: true
draft: false
---

签通配符证书只能走 DNS-01 校验，DNS-01 要求签发工具能往域名里写 TXT 记录。麻烦在于主域名的 DNS 常常没有 API，或者有 API 但一把密钥能改整个账号下所有域名的解析，放在每台服务器上并不放心。acme.sh 的 DNS alias 模式解决的就是这个问题：在主域名上加一条 CNAME，把校验指向另一个专门用来校验的域名，之后签发和续期都只动那个域名。

<!--more-->

## 1. 原理

DNS-01 校验时，CA 去查 `_acme-challenge.<你的域名>` 的 TXT 记录，看里面是不是它给出的那串值。DNS 解析本来就会跟随 CNAME，所以只要把这个名字 CNAME 到别处，CA 最终读到的是别处的 TXT：

```text
CA 查询 TXT _acme-challenge.example.com
  └─ CNAME → _acme-challenge.acme-validate.net
                └─ TXT "Xk3...q9w"   ← acme.sh 通过 DNS API 写入
```

本文用两个示例域名：

- `example.com`：主域名，要给它签证书，DNS 没有 API，或者你不想把它的 API 密钥交给 acme.sh。
- `acme-validate.net`：校验专用域名（alias 域名），托管在 acme.sh 支持的 DNS 服务商上，除了校验不做别的。

主域名的 DNS 只需要手动改一次（加 CNAME），以后的签发、续期都不再碰它，服务器上也只放 alias 域名的 API 密钥。Let's Encrypt 在[校验方式文档](https://letsencrypt.org/docs/challenge-types/)里明确写了可以用 CNAME 把 DNS-01 委托给别的 zone，这不是钻空子。

通配符 `*.example.com` 的校验名也是 `_acme-challenge.example.com`，和 `example.com` 本身是同一个名字，所以一条 CNAME 同时覆盖两者。

## 2. 准备工作

### 2.1 一个 alias 域名

任何你能通过 API 管理解析的域名都行，acme.sh 支持 Cloudflare、阿里云、腾讯云等上百家服务商（[完整列表](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)）。建议专门注册一个便宜域名只做校验，不要拿承载业务的域名来用，原因在第 8 节。

### 2.2 安装 acme.sh

```bash
curl https://get.acme.sh | sh -s email=you@example.com
source ~/.bashrc
```

安装脚本会把 acme.sh 放到 `~/.acme.sh/`，并加一条每天运行的 cron 任务负责续期。

acme.sh 从 3.0 起默认 CA 是 ZeroSSL。想用 Let's Encrypt 就切换默认 CA：

```bash
acme.sh --set-default-ca --server letsencrypt
```

### 2.3 alias 域名的 API 密钥

以 Cloudflare 为例，在控制台创建一个 API Token，权限只给 `Zone → DNS → Edit`，资源只选 `acme-validate.net` 这一个 zone。然后把 Token 和 Zone ID 放进环境变量（设置了 `CF_Zone_ID`，acme.sh 就直接用这个 zone，不再去列账号下的 zone）：

```bash
export CF_Token="cf-api-token"
export CF_Zone_ID="alias-zone-id"
```

其他服务商只是变量名和 `--dns` 参数不同，比如阿里云是 `Ali_Key`、`Ali_Secret` 配 `--dns dns_ali`，腾讯云是 `Tencent_SecretId`、`Tencent_SecretKey` 配 `--dns dns_tencent`，具体看上面的 dnsapi 列表。

签发时 acme.sh 会把这些变量保存下来，续期时自动读取，不用每次 export。但保存的位置要注意：Cloudflare 设置了 `CF_Zone_ID` 时，Token 只存进这张证书自己的配置（`~/.acme.sh/<域名>_ecc/<域名>.conf`），以后签另一张证书还得重新 export；没设 `CF_Zone_ID` 时存进 `~/.acme.sh/account.conf`，所有证书共用。其他服务商大多存在 `account.conf`。

## 3. 在主域名上加 CNAME

到 `example.com` 的 DNS 控制台加一条记录，用 zone 文件的写法是：

```text
_acme-challenge.example.com.  IN  CNAME  _acme-challenge.acme-validate.net.
```

两点要注意：

- 如果 `example.com` 托管在 Cloudflare，这条 CNAME 的代理状态要设成「仅 DNS」（灰色云朵），开了代理就不行。
- `_acme-challenge.example.com` 上如果还留着以前手动签证书时加的 TXT 记录，先删掉。按 DNS 规范，CNAME 不能和同名的其他记录共存，控制台一般会拒绝添加。

加完用 `dig` 确认已经生效：

```bash
dig +short CNAME _acme-challenge.example.com
```

```text
_acme-challenge.acme-validate.net.
```

没有输出就等一会儿再查，DNS 服务商同步到所有权威服务器可能要几分钟。如果加记录之前就查过，本地解析器可能缓存了「不存在」的结果，可以加 `@<example.com 的权威 NS>` 直接问权威服务器。不要跳过这一步：acme.sh 签发前的自检只查 alias 域名，不会帮你检查这条 CNAME（见下一节），CNAME 没生效时去签发，只会浪费 CA 的失败次数。

## 4. 签发证书

同时签 `example.com` 和 `*.example.com`：

```bash
acme.sh --issue --dns dns_cf \
  -d example.com -d '*.example.com' \
  --challenge-alias acme-validate.net
```

`*.example.com` 要加引号，否则 shell 可能把它当成通配符展开。

执行过程大致是：

1. acme.sh 向 CA 下单，拿到两个授权（`example.com` 和 `*.example.com` 各一个），两个都用 DNS-01 校验。
2. 因为指定了 `--challenge-alias`，它不去写 `_acme-challenge.example.com`，而是调用 Cloudflare API，在 `_acme-challenge.acme-validate.net` 上写两条 TXT 记录。两个挑战落在同一个名字上，所以是同名的两条 TXT，值不一样。
3. acme.sh 通过公共 DoH 查询 `_acme-challenge.acme-validate.net`，确认两个值都能查到，最多等 20 分钟。注意它查的是 alias 域名本身，不经过 `example.com` 的 CNAME，所以这一步通过只说明 TXT 写进去了，不说明 CNAME 是对的。
4. 通知 CA 校验，CA 查询 `_acme-challenge.example.com`，顺着 CNAME 读到 TXT，校验通过后签发证书。
5. 删除 alias 域名上的 TXT 记录。

第一次跑建议先加 `--staging` 用 Let's Encrypt 的测试环境，流程走通了再去掉 `--staging` 并加 `--force` 重签一次。正式环境的[速率限制](https://letsencrypt.org/docs/rate-limits/)是同一账号对同一域名每小时最多校验失败 5 次，配置有问题时反复重试很容易撞上，测试环境的限制宽松得多。

签好的证书在 `~/.acme.sh/example.com_ecc/` 下（acme.sh 从 3.0.6 起默认签 ECC 证书，目录带 `_ecc` 后缀；更早的版本默认 RSA，目录没有后缀，本文后面命令里的 `--ecc` 要去掉）。同目录的 `example.com.conf` 里有一行 `Le_ChallengeAlias`，记着这个证书用的 alias 域名，续期时会照此执行。

## 5. 安装到 Nginx

不要让 Nginx 直接引用 `~/.acme.sh/` 里的文件，那个目录的结构是 acme.sh 的内部实现，以后可能变。用 `--install-cert` 把证书复制到固定位置，并指定续期后要执行的命令。目标目录要先建好，acme.sh 不会帮你建：

```bash
mkdir -p /etc/nginx/ssl
acme.sh --install-cert -d example.com --ecc \
  --key-file       /etc/nginx/ssl/example.com.key \
  --fullchain-file /etc/nginx/ssl/example.com.fullchain.pem \
  --reloadcmd      "systemctl reload nginx"
```

Nginx 里引用这两个文件：

```nginx
ssl_certificate     /etc/nginx/ssl/example.com.fullchain.pem;
ssl_certificate_key /etc/nginx/ssl/example.com.key;
```

一定用 `fullchain`（叶子证书加中间证书），不要用只有叶子证书的 `cert`，否则会出现「浏览器正常、curl 报错」，原因见[读懂 SSL 证书链](https://suzf.net/zh/blog/posts/reading-ssl-certificate-chain-debugging/)。装好以后可以用 [SSL 证书检测工具](https://suzf.net/zh/tools/ssl-checker)看一眼链是否完整、SAN 里是否同时有 `example.com` 和 `*.example.com`。

这些路径和 reload 命令同样会保存下来，之后每次续期成功都会自动复制并重载 Nginx。

## 6. 多个域名

### 6.1 共用一个 alias 域名

每个要签的名字都要在它自己的 DNS 上加一条 CNAME，但可以都指向同一个 alias：

```text
_acme-challenge.example.com      → _acme-challenge.acme-validate.net
_acme-challenge.www.example.com  → _acme-challenge.acme-validate.net
_acme-challenge.example.org      → _acme-challenge.acme-validate.net
```

```bash
acme.sh --issue --dns dns_cf \
  -d example.com --challenge-alias acme-validate.net \
  -d www.example.com \
  -d example.org
```

对应规则是按序号，不是按位置：第 1 个 `--challenge-alias` 给第 1 个 `-d`，第 2 个给第 2 个 `-d`，以此类推，和参数写在命令行的哪里无关；`--challenge-alias` 比 `-d` 少时，后面的域名沿用最后一个。所以上面只写一次，三个域名都会用 `acme-validate.net`。`--dns` 也按同样的规则对应。

这个规则有个坑：命令里如果混着不走 alias 的域名，哪怕把 `--challenge-alias` 紧挨着写在 `example.com` 后面，它也会先对上排在第一个的域名。这种情况见 6.3。

### 6.2 不同 alias 域名、不同 DNS 服务商

```bash
acme.sh --issue \
  -d example.com --challenge-alias acme-validate.net  --dns dns_cf \
  -d example.org --challenge-alias acme-validate2.net --dns dns_ali
```

这里 `acme-validate.net` 托管在 Cloudflare，`acme-validate2.net` 托管在阿里云，两家的 API 密钥都要事先 export。

### 6.3 部分域名直接校验

有的域名 DNS 本身就有 API，没必要绕一圈。因为 alias 按序号对应、缺了就沿用，不走 alias 的域名要显式写 `--challenge-alias no` 占住自己的序号：

```bash
acme.sh --issue \
  -d api.example.org --challenge-alias no                --dns dns_ali \
  -d example.com     --challenge-alias acme-validate.net --dns dns_cf
```

假设 `example.org` 托管在阿里云：`api.example.org` 直接用阿里云 API 在 `example.org` 里写 TXT，`example.com` 走 alias，用 Cloudflare API 写 `acme-validate.net`。如果两个 zone 在同一家服务商，用的密钥要同时能管到两个 zone；Cloudflare 这时要 `unset CF_Zone_ID`，改为设置 `CF_Account_ID`，否则所有记录都会写进 `CF_Zone_ID` 指定的那一个 zone。

## 7. `--domain-alias`：自定义校验名

`--challenge-alias acme-validate.net` 要求 CNAME 指向 `_acme-challenge.acme-validate.net`，前缀是固定的。`--domain-alias` 作用相同，但你给的就是完整的校验名，不再自动加 `_acme-challenge.` 前缀：

```text
_acme-challenge.example.com  → example-com.acme-validate.net
_acme-challenge.example.org  → example-org.acme-validate.net
```

```bash
acme.sh --issue --dns dns_cf -d example.com --domain-alias example-com.acme-validate.net
acme.sh --issue --dns dns_cf -d example.org --domain-alias example-org.acme-validate.net
```

共用 `_acme-challenge.acme-validate.net` 本身没有问题，同名下多条 TXT 并存，CA 只要找到自己那一条就算通过。但域名多了以后我更推荐这种写法：几台服务器同时续期时 TXT 不会全堆在一个名字下，出问题时 `dig` 一下就知道是哪个域名的记录。

## 8. 续期和安全

### 续期

安装时加的 cron 每天检查一次，到了续期时间就自动续期，走的还是同样的 alias 流程。续期时间点由 acme.sh 根据证书有效期计算（3.1.3 起还会参考 CA 通过 ARI 给出的建议窗口），一般不用管，确实要固定可以在签发时加 `--days`。**CNAME 记录不要删**，续期还要用；它只是一个指向 TXT 的名字，对域名的正常解析没有任何影响。

想提前验证续期能不能走通，可以强制续一次：

```bash
acme.sh --renew -d example.com --ecc --force
```

### alias 域名就是签发权

只要 `_acme-challenge.example.com` 的 CNAME 还在，谁能往 `_acme-challenge.acme-validate.net` 写 TXT，谁就能给 `example.com` 签证书。所以 alias 模式降低的是**影响范围**，不是敏感程度：

- 泄露的是 alias 域名的密钥，对方能签证书，但改不了 `example.com` 的 A 记录、MX 记录，没法直接把流量和邮件劫持走。
- 但 alias 域名本身要当成证书签发权来保护：注册商账号开二次验证，API Token 只给这个 zone 的 DNS 编辑权限，不要拿它承载其他业务。
- alias 域名一定要开自动续费。它过期被别人注册走，对方就能给所有 CNAME 到它的域名签证书。
- 在 [crt.sh](https://crt.sh/?q=example.com) 之类的证书透明度（CT）日志里能查到为你的域名签发过的所有证书，可以定期看一下，或者订阅 CT 监控告警。
- 某个域名不再需要证书了，就把它的 CNAME 删掉。

## 9. 校验失败时查什么

**acme.sh 一直输出 `Not valid yet`，最后超时**

这是 acme.sh 自己在通知 CA 之前做的检查：它通过 DoH 查 alias 域名上的 TXT，依次尝试 Cloudflare、Google、阿里云、DNSPod 的 DoH，用第一个能连上的。一直查不到，通常是这两种情况：

- TXT 根本没写进去，或者写到了别的 zone。加 `--debug` 重跑，看 DNS API 调用的返回。
- alias 域名的服务商同步到权威服务器很慢，或者服务器出网受限，几个 DoH 都连不上。

后一种可以用 `--dnssleep` 跳过自检，改成固定等待。等待时间要给够，因为 acme.sh 不再确认记录是否已经生效：

```bash
acme.sh --issue --dns dns_cf -d example.com -d '*.example.com' \
  --challenge-alias acme-validate.net --dnssleep 120
```

**CA 返回 `Incorrect TXT record` 或 `No TXT record found`**

在服务器以外的地方逐段检查：

```bash
dig +short CNAME _acme-challenge.example.com
dig +short TXT _acme-challenge.acme-validate.net
dig +short TXT _acme-challenge.example.com @8.8.8.8
```

第一条没有输出说明 CNAME 没加上或拼错了。第二条只在签发过程中能看到 TXT 值，acme.sh 结束后（不管成功失败）会把记录删掉，所以要在它等待时另开一个终端查。第三条从公共解析器看，接近 CA 的视角，应该顺着 CNAME 拿到和第二条同样的值。常见原因：

- CNAME 加在了内网 DNS（split-horizon）里，公网查不到。CA 只看公网权威 DNS。
- Cloudflare 上这条 CNAME 开了代理。
- 同名下还残留旧的 TXT 记录。
- 主域名或 alias 域名开了 DNSSEC 但签名有问题。Let's Encrypt 会校验 DNSSEC，签名不对时解析直接失败。用 [DNSViz](https://dnsviz.net/) 查一下两个 zone。

**CA 返回 CAA 错误**

CAA 记录查的是证书里的域名 `example.com`，不是 alias 域名。如果 `example.com` 的 CAA 只允许 `letsencrypt.org`，而 acme.sh 用的是默认的 ZeroSSL，就会被拒。要么用 `--set-default-ca` 切到 Let's Encrypt，要么在 CAA 里加上 `sectigo.com`（ZeroSSL 的签发方）。签通配符时还要看 `issuewild`：只要存在 `issuewild` 记录，通配符名就只按它来判断。

## 10. 小结

- DNS alias 模式靠一条 `_acme-challenge` CNAME，把 DNS-01 校验委托给另一个有 API 的域名，主域名的 DNS 只手动改一次。
- 签发：`--dns <服务商> --challenge-alias <alias 域名>`；一条 CNAME 同时覆盖 `example.com` 和 `*.example.com`。
- 先用 `dig` 确认 CNAME 生效再签发，acme.sh 的自检不检查它。
- 多个域名时 alias 按序号和 `-d` 对应，缺了就沿用最后一个，不走 alias 的写 `--challenge-alias no`；域名多时用 `--domain-alias` 给每个域名单独的校验名。
- 用 `--install-cert` 装到固定路径并用 fullchain，续期由 cron 自动完成，CNAME 别删。
- alias 域名等于签发权：密钥最小权限，账号开二次验证，看 CT 日志。
