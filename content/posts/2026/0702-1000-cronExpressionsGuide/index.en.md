---
title: "Cron Expressions Explained: A Practical Guide"
slug: "cron expressions explained practical guide"
date: 2026-07-02T10:00:00+08:00
author: "Jeffrey Su"
description: "A field-by-field guide to cron expressions — the five fields, special characters, real-world schedules, and the timezone and day-of-week pitfalls that bite people in production."
categories: ["Developer Tools"]
tags: ["cron", "linux", "scheduling", "devops"]
toc: true
lightgallery: true
draft: false
---

Cron is the quiet workhorse behind almost every scheduled job — log rotation, backups, cache warming, report emails. The syntax is compact, which is exactly why it trips people up: a single misplaced field can turn "every Monday" into "every day." This post walks through cron expressions field by field, covers the special characters, and calls out the mistakes that actually cause incidents.

<!--more-->

### The five fields

A standard cron expression has five space-separated fields:

```
┌───────────── minute        (0 - 59)
│ ┌─────────── hour          (0 - 23)
│ │ ┌───────── day of month  (1 - 31)
│ │ │ ┌─────── month         (1 - 12)
│ │ │ │ ┌───── day of week   (0 - 6, Sunday = 0)
│ │ │ │ │
* * * * *
```

So `30 2 * * *` means "at 02:30 every day," and `0 9 * * 1` means "at 09:00 every Monday."

Some schedulers (Quartz, Spring, some Kubernetes tooling) prepend a **seconds** field, making it six fields. Vixie cron — the one on most Linux boxes — does **not** have seconds. Always know which dialect you are writing for; this is the single most common source of "why did my expression break when I moved it" confusion.

### Special characters

| Character | Meaning | Example |
|-----------|---------|---------|
| `*`       | every value | `* * * * *` = every minute |
| `,`       | list        | `0 0,12 * * *` = midnight and noon |
| `-`       | range       | `0 9-17 * * *` = every hour 09:00–17:00 |
| `/`       | step        | `*/15 * * * *` = every 15 minutes |
| `L`†      | last        | `0 0 L * *` = last day of the month |
| `#`†      | nth weekday | `0 0 * * 5#3` = the 3rd Friday |

† `L` and `#` are Quartz/extended features, not standard Vixie cron.

Steps combine with ranges: `0-30/10` means minutes 0, 10, 20, 30. And `*/20` on the minute field fires at :00, :20, :40 — **not** every 20 minutes rolling from whenever you deployed. Cron always aligns to the wall clock.

### Reading real schedules

- `*/5 * * * *` — every 5 minutes
- `0 * * * *` — top of every hour
- `0 0 * * *` — every day at midnight
- `0 3 * * 1-5` — 03:00 on weekdays
- `0 0 1 * *` — midnight on the 1st of every month
- `15 14 1 * *` — 14:15 on the 1st of every month
- `0 22 * * 1-5` — 22:00 Monday through Friday

### The pitfalls that actually bite

**1. Day-of-month and day-of-week are OR, not AND.** This is the famous one. `0 0 13 * 5` does **not** mean "Friday the 13th." When *both* the day-of-month and day-of-week fields are restricted (neither is `*`), cron runs when **either** matches. So that expression fires on *every* 13th **and** *every* Friday. To get Friday the 13th you need application logic, not cron alone.

**2. Timezone.** Classic cron runs in the server's local time. If your server is UTC but you think in Asia/Shanghai, `0 9 * * *` is 17:00 for you, not 09:00. Daylight-saving transitions make it worse: a job scheduled at 02:30 may run twice or not at all on the switch day. Prefer UTC on servers, or use a scheduler that takes an explicit `CRON_TZ=` / timezone setting.

**3. The seconds field.** Copy a six-field Quartz expression into Linux crontab and the whole thing shifts by one field — your "minute" becomes the "second" cron doesn't have, and behavior goes sideways. Count the fields before you paste.

**4. Overlapping runs.** Cron starts a new run on schedule even if the previous one is still going. A job that usually takes 2 minutes but occasionally takes 20, scheduled `*/5`, will pile up. Guard long jobs with a lock (`flock`) or a scheduler that enforces "no concurrent runs."

**5. Environment.** Cron runs with a minimal environment — no `.bashrc`, a bare `PATH`, often no `HOME` you expect. "Works in my shell, fails in cron" is almost always a missing PATH or env var. Use absolute paths and set what you need at the top of the crontab.

### Test before you trust

The safest way to validate an expression is to see the next few fire times spelled out as real dates, and to read the schedule back in plain English. I built a free, browser-based [Cron Expression Generator](https://suzf.net/en/tools/cron-generator) that does exactly this: edit each field visually, get a human-readable description, and preview the next five executions before you commit anything to a crontab. Everything runs locally in the page — nothing is uploaded.

### Takeaways

- Count your fields (5 vs 6) and know your cron dialect.
- Cron aligns to the wall clock; steps are not "rolling" intervals.
- Day-of-month + day-of-week is OR when both are set.
- Pin the timezone and guard against overlapping runs.
- Always preview the next runs before shipping.

Cron rewards a little precision. Get the fields right once, verify the next runs, and it will quietly do its job for years.
