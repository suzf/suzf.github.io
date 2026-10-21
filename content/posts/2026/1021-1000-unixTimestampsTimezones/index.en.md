---
title: "Unix Timestamps and Time Zones: Seconds, Milliseconds, UTC"
slug: "unix timestamps and time zones"
date: 2026-10-21T10:00:00+08:00
author: "Jeffrey Su"
description: "A Unix timestamp has no time zone; the bugs come from units and display. Seconds vs milliseconds, UTC vs local time, DST, database columns and the 2038 limit."
categories: ["Developer Tools"]
tags: ["timestamp", "timezone", "database", "programming"]
toc: true
draft: false
---

A Unix timestamp is one of the simplest data types in computing: a single integer. Yet "the time is off by eight hours" and "this date says 1970" are among the most common bugs in any codebase. The integer is almost never wrong. The bugs live in two places around it: **the unit** and **the time zone used to display it**.

<!--more-->

## What a Unix timestamp actually is

A Unix timestamp counts the seconds elapsed since **1970-01-01 00:00:00 UTC** (the "epoch"). `1792548000` is one specific instant: 02:00 UTC on 21 October 2026, which is also 10:00 in Beijing and 22:00 the previous evening in New York.

The key property: **a timestamp has no time zone.** It is the same number everywhere on Earth at the same moment. A time zone only comes into play when you turn that number into a calendar date and a clock time for a human to read. Keep those two steps apart in your head and most time bugs become easy to spot.

(Strictly, Unix time pretends every day is exactly 86,400 seconds and ignores leap seconds. For application code that's a feature, not a problem, and the international timekeeping bodies plan to stop adding leap seconds by 2035 anyway.)

## Trap 1: seconds, milliseconds, or something smaller

Different platforms count in different units, and nothing in the number itself says which:

| Digits (today) | Unit | Typical source |
|---|---|---|
| 10 | seconds | `date +%s`, PHP `time()`, most Unix APIs, JWT `exp`/`iat` |
| 13 | milliseconds | JavaScript `Date.now()`, Java `System.currentTimeMillis()` |
| 16 | microseconds | some databases and tracing systems |
| 19 | nanoseconds | Go `time.Now().UnixNano()`, Python `time.time_ns()` |

Mix them up and the result is wildly, obviously wrong, which at least makes it easy to diagnose:

- Seconds read as milliseconds: `1760000000` becomes **21 January 1970**.
- Milliseconds read as seconds: `1760000000000` lands in the **year 57,000-something**, or overflows and throws.

Ten digits will stay the norm for seconds for a long time: the first 11-digit value, `10000000000`, isn't reached until the year 2286. That's why the digit count is a reliable heuristic, and it's exactly what a good converter checks. If you design an API or a schema, put the unit in the name: `created_at_ms`, `expires_at_s`. It costs nothing and removes the guesswork for every future reader.

## Trap 2: the time zone sneaks in at parse and display time

Because the timestamp itself is zone-free, time zone bugs appear where text and timestamps meet. Some well-known traps:

**JavaScript date strings.** `new Date("2026-10-21")` is parsed as **UTC** midnight, but `new Date("2026-10-21T00:00")` is parsed as **local** midnight. In Beijing those are eight hours apart. If you mean a specific instant, always include the offset: `"2026-10-21T00:00:00+08:00"` or a trailing `Z` for UTC.

**Python naive datetimes.** `datetime.utcnow()` returns a datetime with UTC wall-clock values but *no* time zone attached. Call `.timestamp()` on it and Python assumes it's local time, so the result is off by your UTC offset. On a machine set to New York, that's 14,400 seconds (four hours) of silent error. The method is deprecated since Python 3.12; use an aware datetime instead:

```python
from datetime import datetime, timezone

now = datetime.now(timezone.utc)                         # aware, safe
dt = datetime.fromtimestamp(1792548000, tz=timezone.utc)  # 2026-10-21 02:00:00+00:00
```

**The shell.** `date` formats in the machine's zone unless you ask otherwise:

```bash
date +%s                    # current timestamp, seconds
date -u -d @1792548000      # GNU/Linux: show it in UTC
date -u -r 1792548000       # macOS/BSD equivalent
TZ=Asia/Shanghai date -d @1792548000   # show it in a specific zone
```

## Trap 3: "which day is it?" depends on where you are

Midnight 21 October in Beijing is **16:00 UTC on 20 October**. So if you group orders "by day" using UTC dates, a Chinese business day gets split at 08:00 local time, and a daily report never matches what the team sees on their clocks. Decide which zone defines "a day" for each report, and convert to that zone *before* truncating to a date.

Daylight saving time adds another wrinkle. In zones that observe it, some days have 23 or 25 hours, so "tomorrow at the same time" is not always `+ 86400` seconds. When New York leaves DST on 1 November 2026, adding 86,400 seconds to midnight gives you **23:00 the same day**. Do calendar arithmetic with a time zone–aware library (Python `zoneinfo`, `java.time`, `Temporal` in JavaScript), not with raw seconds.

## Trap 4: database columns that quietly drop or shift the zone

- **PostgreSQL:** prefer `timestamptz`. It stores a UTC instant and converts to the session's `TimeZone` when displayed. Plain `timestamp` (without time zone) *silently discards* any offset in the input, so `'2026-10-21 10:00+08'` is stored as just `2026-10-21 10:00`, with nothing recording which zone that was.
- **MySQL:** `TIMESTAMP` converts from the session time zone to UTC on write and back on read, but it only runs until **2038-01-19 03:14:07 UTC**. `DATETIME` has a range up to the year 9999 but stores exactly what you give it, with no zone at all. If you use `DATETIME`, store UTC by convention and make the convention explicit.

## The year 2038

A signed 32-bit integer can hold at most `2147483647`, which as a Unix timestamp is **2038-01-19 03:14:07 UTC**. One second later, a 32-bit counter wraps to a negative number, i.e. December 1901. Modern 64-bit systems use a 64-bit `time_t` and are fine, but the limit still lives in MySQL's `TIMESTAMP` column, older embedded devices, and any file format or protocol field that reserved four bytes for time. Expiry dates and long-lived certificates hit it first, because they point into the future.

## A short set of rules

1. **Store instants in UTC**: a timestamp, `timestamptz`, or ISO 8601 with `Z` or an offset.
2. **Convert to local time only at the edges**, when displaying to a person or parsing their input.
3. **Name the unit** in field and column names (`_s`, `_ms`).
4. **Always send offsets in APIs**: `2026-10-21T10:00:00+08:00`, never a bare `2026-10-21 10:00`.
5. **For future local events** (a meeting at 09:00 in Shanghai next spring), store the local time plus an IANA zone name like `Asia/Shanghai`, not just a UTC instant or a fixed `+08:00`. Zone rules change, and the meeting should stay at 09:00 local.
6. **Do date math with a zone-aware library**, never by adding multiples of 86,400.

## Convert one now

To check a timestamp from a log, a JWT or a database row, the free [Timestamp Converter](https://suzf.net/en/tools/timestamp) tells seconds from milliseconds automatically, switches between local time and UTC, and shows the live current timestamp. It runs entirely in your browser.

Two related posts cover the same ground from other angles: [UUID v7](https://suzf.net/blog/posts/uuid-v4-vs-v7-database-ids/) embeds a millisecond timestamp in every ID, and [cron's time zone trap](https://suzf.net/blog/posts/cron-expressions-explained-practical-guide/) is the scheduling version of trap 3.

## Takeaways

- A Unix timestamp is a zone-free count of seconds since 1970-01-01 UTC.
- 10 digits = seconds, 13 = milliseconds; a 1970 or year-57,000 date means the unit is wrong.
- Time zone bugs happen at parsing and display, so always carry an offset in text.
- Use `timestamptz` in PostgreSQL; know that MySQL `TIMESTAMP` ends in 2038.
- Store UTC, convert at the edges, and keep IANA zone names for future local events.
