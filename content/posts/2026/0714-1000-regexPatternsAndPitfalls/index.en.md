---
title: "Regex in Practice: Handy Patterns and the Traps to Avoid"
slug: "regex patterns and pitfalls"
date: 2026-07-14T10:00:00+08:00
author: "Jeffrey Su"
description: "A working set of regex patterns you'll actually reuse, plus the traps that cause bugs and outages — greedy quantifiers, unanchored matches, catastrophic backtracking, and the 'don't parse HTML with regex' rule."
categories: ["Developer Tools"]
tags: ["regex", "programming", "text-processing"]
toc: true
lightgallery: true
draft: false
---

Regular expressions are a small language for describing text patterns, and like any sharp tool they cut both ways. Used well they replace pages of string-munging code; used carelessly they cause subtle bugs and even denial-of-service outages. This post collects the patterns worth remembering and the traps worth fearing.

<!--more-->

### The pieces you use most

- **Character classes:** `\d` digit, `\w` word char (`[A-Za-z0-9_]`), `\s` whitespace; uppercase negates them (`\D`, `\W`, `\S`). `[abc]` is a custom set, `[^abc]` its negation, `[a-z]` a range.
- **Quantifiers:** `*` (0+), `+` (1+), `?` (0 or 1), `{n}`, `{n,}`, `{n,m}`.
- **Anchors:** `^` start, `$` end, `\b` word boundary. These match *positions*, not characters.
- **Groups:** `(...)` capturing, `(?:...)` non-capturing, `(?<name>...)` named. Backreference with `$1` (replace) or `\1` (pattern).
- **Alternation:** `a|b` means a or b. Mind the precedence: `^cat|dog$` is `(^cat)|(dog$)`, not `^(cat|dog)$`.

### Flags change everything

- `g` — global, find all matches, not just the first.
- `i` — case-insensitive.
- `m` — multiline: `^`/`$` match at each line, not just string start/end.
- `s` — dotall: `.` also matches newlines (by default it doesn't).
- `u` — unicode: needed to handle characters outside the Basic Multilingual Plane and `\p{...}` properties.

A huge share of "my regex doesn't match" bugs are just a missing `m`, `s`, or `u`.

### Patterns worth keeping

```
# Trim leading/trailing whitespace
^\s+|\s+$

# Collapse runs of whitespace to one space
\s+   →   " "

# ISO-ish date  2026-07-14
^\d{4}-\d{2}-\d{2}$

# IPv4 (loose — validates shape, not 0–255 range)
^(\d{1,3}\.){3}\d{1,3}$

# Slug from a title (replace non-alphanumerics)
[^a-z0-9]+   →   "-"
```

A note on the IPv4 pattern: it matches `999.999.999.999`. Regex is great for *shape*; range validation (each octet 0–255) is clumsy in pure regex and better done in code. This is a general principle — use regex to tokenize, use code to validate semantics.

### The traps that cause real bugs

**1. Greedy quantifiers grab too much.** `<.+>` on `<a><b>` matches the *entire* `<a><b>`, not `<a>`, because `+` is greedy and backtracks from the end. Use the lazy version `<.+?>` or, better, a negated class `<[^>]+>`.

**2. Forgetting to anchor.** Validating input with `\d{4}` will happily accept `abc1234xyz` because it only needs to find four digits *somewhere*. To validate a whole string, anchor both ends: `^\d{4}$`.

**3. Unescaped metacharacters.** `.` `+` `*` `?` `(` `)` `[` `]` `{` `}` `^` `$` `|` `\` are special. To match a literal dot in a domain you need `\.` — `example.com` as a pattern also matches `exampleXcom`. When inserting user input into a pattern, escape it first.

**4. Catastrophic backtracking (ReDoS).** Nested or overlapping quantifiers like `(a+)+$` or `(.*)*` can make the engine explore an exponential number of paths on a non-matching input. A single crafted string can pin a CPU core for seconds or minutes — a real denial-of-service vector in web apps. Avoid nested quantifiers over overlapping character sets; prefer possessive quantifiers/atomic groups where supported, or a non-backtracking engine (RE2).

**5. Unicode surprises.** Without the `u` flag, `.` and `\w` think in UTF-16 code units, so an emoji or a CJK character can be counted as two, and `\w` won't match letters like `é` or `中`. Add `u` and use `\p{L}` for "any letter."

**6. Don't parse structured formats with regex.** HTML, JSON, and nested brackets are not *regular* languages — a regex fundamentally can't match arbitrarily nested structure. Use a real parser. Regex is fine for extracting a simple, flat pattern out of such text, not for understanding its structure.

### Build and test interactively

Regex is much easier to get right when you can see matches highlighted live and inspect capture groups as you type. I built a free [Regex Tester](https://suzf.net/en/tools/regex-tester) that highlights matches in real time, shows each capture group, supports the `g/i/m/s/u` flags and `$1` replacement, and ships with common-pattern presets and a cheatsheet — all running locally in your browser.

### Takeaways

- Anchor when validating; make quantifiers lazy or use negated classes.
- Escape user input and literal metacharacters.
- Beware nested quantifiers — that's the ReDoS trap.
- Add `u` for Unicode; don't parse HTML/JSON with regex.
- Test interactively before trusting a pattern in production.
