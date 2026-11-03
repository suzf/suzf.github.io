---
title: "Issuing SSL Certificates with acme.sh DNS Alias Mode, Without Handing Over Your DNS"
slug: "acme sh dns alias mode"
date: 2026-11-03T17:21:55+08:00
author: "Jeffrey Su"
description: "How DNS alias mode works, the CNAME to add, issuing a wildcard certificate with acme.sh and installing it in Nginx, multiple domains and DNS providers, renewal, and what to check when validation fails."
categories: ["Skills Matrix"]
tags: ["ssl", "acme", "letsencrypt", "dns"]
toc: true
draft: false
---

Wildcard certificates can only be validated with DNS-01, and DNS-01 means the issuing tool has to write a TXT record into your zone. The trouble is that the main domain's DNS often has no API, or it has one whose key can edit every record in the account, which you don't want sitting on every server. acme.sh's DNS alias mode solves this: you add one CNAME on the main domain that points validation at a separate, validation-only domain, and from then on issuance and renewal only touch that domain.

<!--more-->

## 1. How it works

For DNS-01, the CA looks up the TXT record at `_acme-challenge.<your domain>` and checks that it holds the value it handed out. DNS resolution follows CNAMEs anyway, so if that name is a CNAME to somewhere else, the CA ends up reading the TXT record over there:

```text
CA queries TXT _acme-challenge.example.com
  └─ CNAME → _acme-challenge.acme-validate.net
                └─ TXT "Xk3...q9w"   ← written by acme.sh through the DNS API
```

This post uses two example domains:

- `example.com`: the main domain that needs a certificate. Its DNS has no API, or you don't want to give that API key to acme.sh.
- `acme-validate.net`: the validation-only (alias) domain, hosted at a DNS provider acme.sh supports, used for nothing else.

You edit the main domain's DNS by hand once (to add the CNAME). Issuance and renewal never touch it again, and the only API key on the server belongs to the alias domain. Let's Encrypt's [challenge types documentation](https://letsencrypt.org/docs/challenge-types/) explicitly says you can delegate DNS-01 to another zone with a CNAME, so this isn't a loophole.

The validation name for the wildcard `*.example.com` is also `_acme-challenge.example.com`, the same name as for `example.com` itself, so one CNAME covers both.

## 2. Preparation

### 2.1 An alias domain

Any domain whose DNS you can manage through an API will do. acme.sh supports over a hundred providers, including Cloudflare, Route 53, Alibaba Cloud and Tencent Cloud ([full list](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)). I recommend registering a cheap domain just for validation rather than reusing one that serves anything; section 8 explains why.

### 2.2 Install acme.sh

```bash
curl https://get.acme.sh | sh -s email=you@example.com
source ~/.bashrc
```

The installer puts acme.sh in `~/.acme.sh/` and adds a daily cron job that handles renewal.

Since 3.0, acme.sh uses ZeroSSL as its default CA. To use Let's Encrypt, change the default:

```bash
acme.sh --set-default-ca --server letsencrypt
```

### 2.3 An API key for the alias domain

With Cloudflare, create an API token with only `Zone → DNS → Edit`, limited to the `acme-validate.net` zone. Then export the token and zone ID (with `CF_Zone_ID` set, acme.sh uses that zone directly instead of listing the zones in the account):

```bash
export CF_Token="cf-api-token"
export CF_Zone_ID="alias-zone-id"
```

Other providers only differ in variable names and the `--dns` value: Alibaba Cloud is `Ali_Key` and `Ali_Secret` with `--dns dns_ali`, Tencent Cloud is `Tencent_SecretId` and `Tencent_SecretKey` with `--dns dns_tencent`. See the dnsapi list above for the rest.

During issuance acme.sh saves these values and reads them back on renewal, so you don't export them every time. Where they're saved matters, though: with `CF_Zone_ID` set, the Cloudflare token goes only into this certificate's own config (`~/.acme.sh/<domain>_ecc/<domain>.conf`), so you have to export it again for the next certificate; without `CF_Zone_ID` it goes into `~/.acme.sh/account.conf`, shared by every certificate. Most other providers save to `account.conf`.

## 3. Add the CNAME on the main domain

In `example.com`'s DNS console, add this record (shown in zone file syntax):

```text
_acme-challenge.example.com.  IN  CNAME  _acme-challenge.acme-validate.net.
```

Two things to watch:

- If `example.com` is on Cloudflare, set this CNAME's proxy status to "DNS only" (grey cloud). It doesn't work proxied.
- If `_acme-challenge.example.com` still has a TXT record from an earlier manual issuance, delete it first. DNS rules don't allow a CNAME alongside other records at the same name, and consoles usually refuse to add it.

Then confirm with `dig` that it's live:

```bash
dig +short CNAME _acme-challenge.example.com
```

```text
_acme-challenge.acme-validate.net.
```

If nothing comes back, wait and try again: it can take a few minutes for the provider to update all its authoritative servers. If you queried before adding the record, your local resolver may have cached the "doesn't exist" answer; add `@<example.com's authoritative NS>` to ask the authoritative server directly. Don't skip this check: acme.sh's own pre-check only looks at the alias domain and never checks this CNAME (see the next section), so issuing before the CNAME is live just burns failed validations at the CA.

## 4. Issue the certificate

To get `example.com` and `*.example.com` on one certificate:

```bash
acme.sh --issue --dns dns_cf \
  -d example.com -d '*.example.com' \
  --challenge-alias acme-validate.net
```

Quote `*.example.com`, or the shell may try to expand it as a glob.

Roughly what happens:

1. acme.sh places an order with the CA and gets two authorizations, one for `example.com` and one for `*.example.com`, and validates both with DNS-01.
2. Because of `--challenge-alias`, it doesn't write `_acme-challenge.example.com`. It calls the Cloudflare API and writes two TXT records at `_acme-challenge.acme-validate.net`. Both challenges land on the same name, so you get two TXT records with different values under one name.
3. acme.sh queries `_acme-challenge.acme-validate.net` through public DoH and waits, for up to 20 minutes, until both values are visible. It queries the alias name directly, not through `example.com`'s CNAME, so passing this step only shows the TXT records were written, not that the CNAME is right.
4. It tells the CA to validate. The CA queries `_acme-challenge.example.com`, follows the CNAME to the TXT records, and issues the certificate.
5. acme.sh deletes the TXT records from the alias domain.

On the first run, add `--staging` to use Let's Encrypt's staging environment. Once that works, drop `--staging` and add `--force` to issue for real. Production [rate limits](https://letsencrypt.org/docs/rate-limits/) allow one account 5 failed validations per domain per hour, which retrying a broken setup hits quickly; staging's limits are much higher.

The certificate ends up in `~/.acme.sh/example.com_ecc/` (since 3.0.6 acme.sh issues ECC certificates by default, hence the `_ecc` suffix; older versions default to RSA with no suffix, so drop `--ecc` from the later commands). The `example.com.conf` file in that directory has a `Le_ChallengeAlias` line that records the alias domain, which renewal reuses.

## 5. Install it in Nginx

Don't point Nginx at the files inside `~/.acme.sh/`; that layout is an acme.sh implementation detail and may change. Use `--install-cert` to copy the certificate to a fixed location and set the command to run after each renewal. Create the target directory first; acme.sh won't:

```bash
mkdir -p /etc/nginx/ssl
acme.sh --install-cert -d example.com --ecc \
  --key-file       /etc/nginx/ssl/example.com.key \
  --fullchain-file /etc/nginx/ssl/example.com.fullchain.pem \
  --reloadcmd      "systemctl reload nginx"
```

And reference those files in Nginx:

```nginx
ssl_certificate     /etc/nginx/ssl/example.com.fullchain.pem;
ssl_certificate_key /etc/nginx/ssl/example.com.key;
```

Always use the `fullchain` file (leaf plus intermediates), not the leaf-only `cert`, or you'll get "works in the browser, fails in curl"; [Reading an SSL Certificate Chain](https://suzf.net/en/blog/posts/reading-ssl-certificate-chain-debugging/) explains why. Once it's installed, the [SSL Certificate Checker](https://suzf.net/en/tools/ssl-checker) shows whether the chain is complete and whether the SAN list has both `example.com` and `*.example.com`.

The paths and reload command are saved too, so every successful renewal copies the new files and reloads Nginx.

## 6. Multiple domains

### 6.1 Sharing one alias domain

Every name on the certificate needs its own CNAME in its own zone, but they can all point at the same alias:

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

The pairing goes by count, not position: the first `--challenge-alias` goes to the first `-d`, the second to the second `-d`, and so on, wherever they appear on the command line. When there are fewer `--challenge-alias` values than `-d` options, the remaining domains reuse the last one. So one `--challenge-alias` above covers all three domains. `--dns` pairs the same way.

That rule has a trap: if the command mixes in a domain that shouldn't use the alias and it comes first, the first `--challenge-alias` goes to it, even if you wrote the option right after `example.com`. Section 6.3 covers that case.

### 6.2 Different alias domains and DNS providers

```bash
acme.sh --issue \
  -d example.com --challenge-alias acme-validate.net  --dns dns_cf \
  -d example.org --challenge-alias acme-validate2.net --dns dns_ali
```

Here `acme-validate.net` is on Cloudflare and `acme-validate2.net` is on Alibaba Cloud, so export the API keys for both first.

### 6.3 Validating some domains directly

Some domains already have DNS with an API, and there's no point routing them through an alias. Because aliases pair by count and a missing one is reused, give those domains `--challenge-alias no` to hold their place:

```bash
acme.sh --issue \
  -d api.example.org --challenge-alias no                --dns dns_ali \
  -d example.com     --challenge-alias acme-validate.net --dns dns_cf
```

Assuming `example.org` is on Alibaba Cloud, `api.example.org` gets its TXT record written straight into `example.org` with the Alibaba Cloud API, while `example.com` goes through the alias, written into `acme-validate.net` with the Cloudflare API. If both zones are at the same provider, the key has to cover both; with Cloudflare, `unset CF_Zone_ID` and set `CF_Account_ID` instead, or every record goes into the zone `CF_Zone_ID` names.

## 7. `--domain-alias`: choosing the validation name

`--challenge-alias acme-validate.net` requires the CNAME to target `_acme-challenge.acme-validate.net`; the prefix is fixed. `--domain-alias` does the same job, but you pass the full validation name and no `_acme-challenge.` prefix is added:

```text
_acme-challenge.example.com  → example-com.acme-validate.net
_acme-challenge.example.org  → example-org.acme-validate.net
```

```bash
acme.sh --issue --dns dns_cf -d example.com --domain-alias example-com.acme-validate.net
acme.sh --issue --dns dns_cf -d example.org --domain-alias example-org.acme-validate.net
```

Sharing `_acme-challenge.acme-validate.net` works fine: several TXT records can sit under one name, and the CA passes as long as it finds its own. But once there are many domains I prefer this form: when several servers renew at once their TXT records don't all pile up under one name, and when something goes wrong one `dig` tells you which domain a record belongs to.

## 8. Renewal and security

### Renewal

The cron job from the installer runs daily and renews the certificate when it's due, using the same alias flow. acme.sh works out when it's due from the certificate's validity period (since 3.1.3 it also follows the renewal window the CA suggests through ARI). You normally don't need to touch it; if you must pin it, pass `--days` when issuing. **Don't delete the CNAME**: renewal needs it, and it's only a name pointing at a TXT record, so it has no effect on the rest of the domain's DNS.

To check now that renewal works, force one:

```bash
acme.sh --renew -d example.com --ecc --force
```

### The alias domain is issuance power

As long as the `_acme-challenge.example.com` CNAME exists, anyone who can write TXT records at `_acme-challenge.acme-validate.net` can get certificates for `example.com`. Alias mode reduces the **blast radius**, not the sensitivity:

- If the alias domain's key leaks, the attacker can issue certificates but can't change `example.com`'s A or MX records, so they can't simply redirect your traffic and mail.
- Still, protect the alias domain as what it is, the power to issue certificates: two-factor authentication on the registrar account, an API token limited to DNS edits on that one zone, and no other use for the domain.
- Turn on auto-renewal for the alias domain. If it lapses and someone else registers it, they can issue certificates for every domain that CNAMEs to it.
- Certificate Transparency logs such as [crt.sh](https://crt.sh/?q=example.com) list every certificate issued for your domain. Check them now and then, or subscribe to a CT monitoring alert.
- When a domain no longer needs certificates, delete its CNAME.

## 9. When validation fails

**acme.sh keeps printing `Not valid yet`, then times out**

This is acme.sh's own check before it asks the CA to validate: it looks up the TXT records on the alias domain over DoH, trying Cloudflare, Google, Alibaba Cloud and DNSPod in turn and using the first one it can reach. When it never sees them, it's usually one of two things:

- The TXT records were never written, or went into a different zone. Rerun with `--debug` and look at the DNS API responses.
- The alias domain's provider is slow to update its authoritative servers, or the server's outbound access is restricted and none of the DoH endpoints are reachable.

For the second case, `--dnssleep` skips the check and waits a fixed time instead. Make the wait long enough, because acme.sh no longer confirms the records are live:

```bash
acme.sh --issue --dns dns_cf -d example.com -d '*.example.com' \
  --challenge-alias acme-validate.net --dnssleep 120
```

**The CA returns `Incorrect TXT record` or `No TXT record found`**

Check each hop from outside the server:

```bash
dig +short CNAME _acme-challenge.example.com
dig +short TXT _acme-challenge.acme-validate.net
dig +short TXT _acme-challenge.example.com @8.8.8.8
```

No output from the first means the CNAME is missing or misspelled. The second only shows the TXT values during issuance: acme.sh deletes them when it finishes, success or failure, so run it from another terminal while acme.sh is waiting. The third asks a public resolver, close to the CA's point of view, and should return the same values as the second through the CNAME. Common causes:

- The CNAME was added only to internal (split-horizon) DNS, so it isn't visible publicly. The CA only looks at public authoritative DNS.
- The CNAME is proxied on Cloudflare.
- An old TXT record is still sitting at the same name.
- The main or alias domain has DNSSEC with broken signatures. Let's Encrypt validates DNSSEC, and bad signatures make the lookup fail outright. Check both zones with [DNSViz](https://dnsviz.net/).

**The CA returns a CAA error**

CAA is checked for the names on the certificate, `example.com`, not the alias domain. If `example.com`'s CAA allows only `letsencrypt.org` and acme.sh is using its default ZeroSSL, the order is refused. Either switch to Let's Encrypt with `--set-default-ca`, or add `sectigo.com` (ZeroSSL's issuer) to the CAA record. For wildcards, also check `issuewild`: if any `issuewild` record exists, it alone decides for the wildcard name.

## 10. Summary

- DNS alias mode uses one `_acme-challenge` CNAME to delegate DNS-01 validation to another domain that has an API, so you edit the main domain's DNS by hand only once.
- Issue with `--dns <provider> --challenge-alias <alias domain>`; one CNAME covers both `example.com` and `*.example.com`.
- Confirm the CNAME with `dig` before issuing; acme.sh's pre-check doesn't look at it.
- With several domains, aliases pair with `-d` by count and a missing one reuses the last alias; use `--challenge-alias no` for domains that validate directly, and `--domain-alias` to give each domain its own validation name.
- Install with `--install-cert` to fixed paths using the fullchain file. Cron handles renewal; keep the CNAME.
- The alias domain is issuance power: least-privilege key, two-factor on the account, and watch the CT logs.
