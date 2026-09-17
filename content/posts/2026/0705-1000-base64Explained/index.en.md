---
title: "Base64 Explained: What It Is and When Not to Use It"
slug: "base64 explained when not to use it"
date: 2026-07-05T10:00:00+08:00
author: "Jeffrey Su"
description: "How Base64 turns binary into text, why the output is ~33% bigger, the difference between standard and URL-safe alphabets, and the common mistake of treating it as encryption."
categories: ["Developer Tools"]
tags: ["base64", "encoding", "web", "http"]
toc: true
lightgallery: true
draft: false
---

Base64 shows up everywhere: data URIs in CSS, JWT segments, email attachments, API payloads, `kubectl get secret` output. It is one of those things everyone uses and few people can explain precisely. This post covers how it works, why it exists, and the two misconceptions that cause real bugs.

<!--more-->

### The problem Base64 solves

A lot of systems were designed to move **text**, not arbitrary bytes. Email (SMTP), older HTTP headers, JSON, XML, URLs — historically these could mangle or choke on raw binary: null bytes, control characters, bytes above 127. Base64 sidesteps the whole problem by re-encoding **any** binary data using only 64 "safe" printable ASCII characters that survive those channels intact.

So Base64 is a **transport encoding**. Its job is to make binary data text-safe — nothing more.

### How it works

Base64 processes input **3 bytes at a time**. Three bytes = 24 bits. Those 24 bits are re-sliced into **four 6-bit groups**, and each 6-bit group (a value 0–63) maps to one character in the alphabet:

```
Input bytes:   M           a           n
ASCII:         77          97          110
Bits:          01001101    01100001    01101110
Regrouped:     010011  010110  000101  101110
Value:         19      22      5       46
Base64:        T       W       F       u
```

So `Man` → `TWFu`. The standard alphabet is `A–Z`, `a–z`, `0–9`, `+`, `/`.

When the input isn't a multiple of 3 bytes, Base64 pads the output with `=` so the length is always a multiple of 4. One leftover byte → two chars + `==`; two leftover bytes → three chars + `=`.

### Why the output is ~33% larger

Every 3 bytes (24 bits) become 4 characters (each character carrying 6 useful bits). That's a 4:3 ratio — a **33% size increase**, before padding. This matters: base64-ing a 1 MB image into a data URI makes it ~1.37 MB of text in your HTML/CSS bundle. Fine for a tiny icon, wasteful for anything large.

### Standard vs URL-safe

The standard alphabet uses `+` and `/`, but both have special meaning in URLs (`/` is a path separator, `+` can decode to a space in query strings). So there's a **URL-safe** variant (RFC 4648 §5) that swaps them:

- `+` → `-`
- `/` → `_`

JWTs use URL-safe Base64 **without padding**. If you decode a JWT segment with a strict standard-Base64 decoder, it may fail on the missing `=` or the `-`/`_` characters. When something "won't decode," an alphabet mismatch is the usual culprit.

### Two misconceptions that cause bugs

**1. "Base64 is encryption / it hides my data."** It does not. Base64 is fully reversible by anyone, with no key. Putting a password or API key in Base64 is exactly as secure as writing it in plain text — arguably worse, because it *looks* obscured and invites complacency. Kubernetes Secrets, for example, are Base64-encoded, not encrypted; that's why cluster RBAC (and encryption-at-rest) matters. Use Base64 for transport, never for protection.

**2. "Base64 handles Unicode automatically."** Base64 encodes **bytes**, not characters. To Base64 a string like `café`, you first have to turn it into bytes with a character encoding — almost always UTF-8. Skip that step (or use the wrong encoding) and you get mojibake on the other side. In the browser, the old `btoa()` throws on non-Latin1 characters for exactly this reason; you must UTF-8-encode first.

### Where Base64 is the right tool

- Embedding small assets (icons, fonts) as `data:` URIs to save a request
- Encoding binary in JSON/XML fields that only accept strings
- Email MIME attachments
- Encoding raw bytes for a URL or HTTP header safely

And where it isn't: large files (the 33% tax + no streaming), or anything you think needs to be "hidden."

### Try it

If you want to see encoding and decoding happen live — including dragging in an image to get its data URI, or decoding a Base64 blob back into a downloadable file — I built a free [Base64 Encoder / Decoder](https://suzf.net/en/tools/base64) that runs entirely in your browser. Nothing you paste or drop leaves your device, which matters if you're inspecting tokens or internal data.

### Takeaways

- Base64 is a transport encoding: binary → text-safe, ~33% bigger.
- It is **not** encryption. No key, fully reversible.
- Encode text to bytes (UTF-8) *before* Base64.
- Watch the alphabet: standard vs URL-safe, padding vs none.
