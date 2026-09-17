---
title: "Reading an SSL Certificate Chain (and Debugging a Broken One)"
slug: "reading ssl certificate chain debugging"
date: 2026-07-11T10:00:00+08:00
author: "Jeffrey Su"
description: "Leaf, intermediate, root — what each certificate in a TLS chain is, how the chain is validated, and why 'works in my browser, fails in curl' almost always means a missing intermediate."
categories: ["Developer Tools"]
tags: ["ssl", "tls", "security", "https"]
toc: true
lightgallery: true
draft: false
---

Almost every TLS problem that isn't "the cert expired" is a **chain** problem. The site loads fine in Chrome but `curl` complains, or your mobile app rejects the certificate that the browser accepts. Nine times out of ten the cause is the same: a missing intermediate certificate. To fix it reliably you need to know what a certificate chain is and how validation actually works.

<!--more-->

### The three kinds of certificate

A TLS chain is a short list of certificates that link the server back to a trusted root:

1. **Leaf (end-entity) certificate** — the one for your actual domain, `example.com`. It's signed by an intermediate.
2. **Intermediate certificate(s)** — one or more certificates belonging to the Certificate Authority (CA). Each is signed by the one above it. Intermediates exist so the CA can keep its ultra-valuable root offline and rotate signing certs without touching it.
3. **Root certificate** — the CA's self-signed anchor. Roots live in the **trust store** shipped with your OS and browsers. You do **not** send the root; the client already has it.

The chain is a signature ladder: root signs intermediate, intermediate signs leaf. Trust flows down.

### How validation works

When a client connects, the server presents its leaf plus any intermediates. The client then tries to build a path from the leaf up to a certificate it already trusts in its local root store. For each link it checks:

- The signature is valid (each cert was really signed by the next one up).
- The current time is within each cert's validity window.
- The leaf's names (Subject Alternative Names) actually cover the hostname you connected to.
- Nothing in the chain is revoked (via CRL/OCSP).

If it can build an unbroken path to a trusted root and every check passes, you get the padlock. Break any link and validation fails.

### Why "works in browser, fails in curl"

This is the classic symptom of a **missing intermediate**. Here's the trick: the server is *supposed* to send the leaf **and** the intermediates. If it only sends the leaf, some clients can still succeed because:

- Browsers cache intermediates they've seen before, and often fetch a missing one automatically via the "AIA" URL embedded in the cert.
- `curl`, `openssl`, many language HTTP libraries, and lots of mobile stacks do **not** do that fetching. They see leaf → ??? → and give up with "unable to get local issuer certificate."

So the browser papers over the server's misconfiguration and curl exposes it. The fix is on the **server**: configure it to serve the **full chain** (leaf + all intermediates), usually a `fullchain.pem`, not just the leaf `cert.pem`. Order matters too — leaf first, then intermediates in ascending order.

### Common chain failures and what they mean

- **"unable to get local issuer certificate"** — missing intermediate; serve the full chain.
- **"certificate has expired"** — check the leaf *and* every intermediate; an expired intermediate breaks everything (this has caused large outages).
- **"self-signed certificate in certificate chain"** — the chain terminates at something not in the client's trust store.
- **"hostname mismatch"** — the SAN list doesn't include the name you connected to. Note: the legacy Common Name (CN) is ignored by modern clients; only SANs count.
- **Wrong order** — some strict servers/clients reject a chain whose certs aren't in leaf-to-root order.

### Inspect a chain quickly

The classic CLI check is:

```
openssl s_client -connect example.com:443 -servername example.com
```

...but reading raw `openssl` output is a chore. To see the whole chain laid out — leaf, intermediates, root, each issuer/subject, validity dates, days-until-expiry, and the SAN list — I built a free [SSL Certificate Checker](https://suzf.net/en/tools/ssl-checker). Enter a domain (custom ports supported, e.g. `host:8443`) and it makes a real TLS connection and visualizes the chain and server details, so a missing or expiring intermediate is obvious at a glance.

### Takeaways

- A chain is leaf → intermediate(s) → root; trust flows down by signatures.
- Clients don't need the root (it's in their trust store); they *do* need the intermediates.
- "Works in browser, fails in curl" = serve the **full chain** on the server.
- Watch intermediate expiry, hostname coverage (SANs), and cert order.
