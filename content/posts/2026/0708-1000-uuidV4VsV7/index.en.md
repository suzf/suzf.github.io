---
title: "UUID v4 vs v7: Which Should You Use for Database IDs?"
slug: "uuid v4 vs v7 database ids"
date: 2026-07-08T10:00:00+08:00
author: "Jeffrey Su"
description: "Random UUID v4 is great for uniqueness but terrible for database index locality. Time-ordered UUID v7 fixes that. Here's how each works and when to pick which."
categories: ["Developer Tools"]
tags: ["uuid", "database", "postgres", "identifiers"]
toc: true
lightgallery: true
draft: false
---

If you've reached for a UUID as a primary key, you've probably used **v4** — the fully random one. It's the default almost everywhere. But if your UUIDs are the clustered primary key of a large, write-heavy table, v4 can quietly hurt performance, and **v7** is usually the better choice. Here's the why.

<!--more-->

### What a UUID actually is

A UUID is a 128-bit identifier, normally written as 32 hex digits in five groups: `550e8400-e29b-41d4-a716-446655440000`. The **version** (the first digit of the third group) tells you how those 128 bits were generated. The whole point is to create identifiers that are unique *without* coordinating with a central authority — any machine can mint one and collisions are astronomically unlikely.

### UUID v4 — random

v4 fills almost all 128 bits with cryptographically random data (6 bits are fixed for the version and variant). That's 122 random bits.

- **Pros:** dead simple, no coordination, no leaked information, effectively zero collision risk.
- **Con:** the value is *unordered*. Two IDs generated one millisecond apart are completely unrelated numerically.

For most uses — an idempotency key, a session token, a public reference in a URL — v4 is perfect. The problem only appears when a v4 UUID becomes a **database primary key at scale**.

### Why random hurts as a primary key

Most databases store rows in a B-tree ordered by the primary key (in InnoDB and SQL Server the table is *physically* clustered by it). When keys arrive in order, every insert lands at the "end" — the same hot page stays in memory, pages fill neatly, the index stays compact.

Random keys destroy this. Each v4 insert targets a **random** spot in the tree, so:

- The database must read a random, likely-not-cached page for almost every insert → more I/O.
- Pages split and fragment, wasting space and bloating the index.
- Cache hit rates drop because the "working set" is the whole index, not the tail.

On a small table you'll never notice. On a table with tens of millions of rows and heavy inserts, v4 primary keys measurably increase write latency and index size.

### UUID v7 — time-ordered

v7 (standardized in RFC 9562, 2024) is built to fix exactly this. Its layout is:

- **48 bits:** a Unix timestamp in **milliseconds**
- **74 bits:** random
- plus the fixed version/variant bits

Because the high bits are a timestamp, v7 UUIDs generated over time are **roughly sortable** and monotonically increasing. Inserts land near the end of the index — you get v4's decentralized uniqueness **and** the insert locality of an auto-increment integer. As a bonus, `ORDER BY id` is approximately chronological, and range scans by creation time become cheap.

The random 74 bits keep them unguessable enough and collision-safe within the same millisecond.

### Choosing

| Use case | Pick |
|----------|------|
| Clustered/primary key on a large table | **v7** |
| Public identifier where ordering leaks info you don't want exposed | **v4** |
| Idempotency key, session token, correlation ID | **v4** (either works) |
| You need created-time ordering for free | **v7** |
| Distributed inserts into one hot table | **v7** |

One caveat for v7: the embedded timestamp **reveals roughly when the record was created**. Usually that's harmless or even useful, but if the creation time is sensitive (or you don't want to expose ordering/volume to outside users), prefer v4 for the public-facing ID.

A common pattern: **v7 for the internal primary key, v4 (or a separate opaque token) for anything exposed publicly.**

### Generate some to inspect

If you want to eyeball the difference — generate a batch of v4 and v7 side by side and watch how v7 values share a sorted prefix while v4 values look scrambled — I built a free [UUID Generator](https://suzf.net/en/tools/uuid-generator) that does both v4 and v7, in batches, with uppercase and no-dash options. It runs locally in the browser using the platform's crypto RNG.

### Takeaways

- v4 = fully random: perfect for tokens and public refs, poor as a large clustered key.
- v7 = timestamp + random: sortable, index-friendly, ideal for primary keys.
- v7 leaks creation time; use v4 publicly when that matters.
- A hybrid (v7 internal, v4 external) is often the cleanest answer.
