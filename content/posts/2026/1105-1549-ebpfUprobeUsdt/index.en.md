---
title: "Tracing User-Space Programs with eBPF uprobes and USDT"
slug: "ebpf uprobe usdt"
date: 2026-11-05T15:49:50+08:00
author: "Jeffrey Su"
description: "How uprobes, uretprobes and USDT probes work; reading a user-space function's arguments, return value and latency with bpftrace; tracing libc and OpenSSL to see TLS plaintext; Python's USDT probes for audit events and GC pauses; and the pitfalls with Go, replaced binaries and overhead."
categories: ["Skills Matrix"]
tags: ["ebpf", "linux", "observability", "bpftrace"]
toc: true
draft: false
---

The [first post](https://suzf.net/en/blog/posts/ebpf-getting-started/) covered how eBPF works and the [second](https://suzf.net/en/blog/posts/ebpf-troubleshooting-playbook/) used ready-made tools to troubleshoot, and most of what they looked at was the kernel: scheduling, disks, TCP. Plenty of problems live in the application itself, though: why one function is slow, what arguments it was called with, what exactly went out before it was encrypted. This post puts probes inside user-space programs, so you can watch function calls without changing code or restarting anything.

<!--more-->

Every command here was run on Ubuntu 24.04 (kernel 6.8, bpftrace 0.20.2). The output comes from a test VM running under QEMU emulation, so anything measured in time is inflated. All bpftrace commands need root.

## 1. How uprobes work

A **uprobe** attaches an eBPF program to any instruction in a user-space program, most often a function's entry. When you attach one, the kernel replaces the instruction at that address with a breakpoint (`int3` on x86). When the program reaches it, it traps into the kernel, the kernel runs your eBPF program, then executes the displaced instruction from a special page of memory (or emulates it) and lets the program carry on.

Three things are worth remembering:

- **The probe is on the file, not the process.** The kernel records a uprobe as "this file, this offset", so every process that maps that binary or library hits it, including processes started after you attached. To watch one process, hand its PID to the kernel with `-p`; section 4 explains why filtering inside the script isn't enough.
- **Every hit is a round trip into the kernel.** A normal function call takes nanoseconds; a uprobe hit takes on the order of a microsecond. On a function called a few times a second that doesn't matter. On `malloc()`, called millions of times a second, the application slows down noticeably.
- **uretprobes work by rewriting the return address.** To fire when a function returns, the kernel swaps the return address on the stack for the address of a trampoline, and it does this at function entry. On return the function jumps to the trampoline, traps into the kernel, and then continues to the real return address. Runtimes that inspect or move their own stacks, such as Go, can't cope with that; section 7 shows what happens.

**USDT** (User Statically-Defined Tracing) is the other route. Developers put probes in the code; once compiled, each one is just a `nop` instruction plus a note in the ELF file's `.note.stapsdt` section saying where the probe is and where its arguments live. Untraced, it costs next to nothing; when you attach, the kernel puts a uprobe on that `nop`. The advantage is that probe names and arguments are maintained by the developers, so they don't change from release to release the way function names do.

## 2. A sample program

This small program pretends to be an order-processing service. Each order takes 0 to 19 ms of "work", the program rests 50 ms after each one, and orders for more than 8 items are rejected. It also has a USDT probe, declared with `DTRACE_PROBE3`:

```c
// orders.c
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/sdt.h>

static const char *skus[] = { "apple", "banana", "cherry" };

int handle_order(int id, const char *sku, int qty)
{
    printf("order %d: %d x %s\n", id, qty, sku);
    usleep(1000 * (rand() % 20));      /* 0-19 ms of "work" */
    if (qty > 8)
        return -1;                     /* reject large orders */
    DTRACE_PROBE3(orders, shipped, id, sku, qty);
    return 0;
}

int main(void)
{
    srand(time(NULL));
    for (int id = 1; ; id++) {
        handle_order(id, skus[rand() % 3], rand() % 10 + 1);
        usleep(50 * 1000);
    }
}
```

`sys/sdt.h` comes from the `systemtap-sdt-dev` package. It's only a header and adds no runtime dependency. Compile with `-g` so you can use argument names later instead of positions, then run two copies in the background:

```bash
sudo apt install systemtap-sdt-dev
gcc -O2 -g -o orders orders.c
./orders > /dev/null &
./orders > /dev/null &
```

## 3. Finding something to attach to

`bpftrace -l` lists every symbol in a binary that a uprobe can attach to:

```bash
sudo bpftrace -l 'uprobe:./orders:*'
```

```text
uprobe:./orders:__do_global_dtors_aux
uprobe:./orders:_fini
uprobe:./orders:_init
uprobe:./orders:_start
uprobe:./orders:deregister_tm_clones
uprobe:./orders:frame_dummy
uprobe:./orders:handle_order
uprobe:./orders:main
uprobe:./orders:register_tm_clones
```

If the binary was built with `-g`, `-lv` also reads the arguments from the debug info:

```bash
sudo bpftrace -lv 'uprobe:./orders:handle_order'
```

```text
uprobe:./orders:handle_order
    int id
    const char* sku
    int qty
```

Whether the function you want is in that list depends on how the program was built and packaged. I tried two common cases with the same code:

- **A stripped binary.** `strip` removes the symbol table, and `bpftrace -l` lists nothing at all. Most distribution packages are stripped, leaving only the dynamically exported symbols, which for a library means its public API. Debug symbols usually ship separately in a `-dbgsym` package.
- **An inlined function.** Make `handle_order` `static` and compile it with `-O2` as `orders_static`: it's only called once, so the compiler inlines it into `main` and the function disappears from the symbol table. `bpftrace -e 'uprobe:./orders_static:handle_order {}'` then fails with `No probes to attach`. Worse is the case where the symbol survives but some call sites were inlined: the probe attaches and silently misses part of the calls.

Without root, `nm orders | grep handle_order` shows the symbol table and `readelf -n orders` shows the USDT probes.

## 4. Arguments, return values and latency

In a uprobe, `arg0`, `arg1` and so on are the function's first arguments (on x86-64, read from `rdi`, `rsi`, `rdx` and the other registers the calling convention uses). Pointers to strings need `str()`:

```bash
sudo bpftrace -e 'uprobe:./orders:handle_order {
    printf("pid=%d id=%d sku=%s qty=%d\n", pid, arg0, str(arg1), arg2);
}'
```

```text
Attaching 1 probe...
pid=118 id=226 sku=cherry qty=5
pid=117 id=226 sku=cherry qty=5
pid=118 id=227 sku=apple qty=5
pid=117 id=227 sku=apple qty=5
pid=118 id=228 sku=banana qty=7
```

Both processes show up: that's the probe living on the file. They print identical orders because they started in the same second and `srand(time(NULL))` gave them the same seed; it isn't one call printed twice. With debug info you can also write `args.id`, `str(args.sku)` and `args.qty` instead of remembering the order.

If `str()` comes back empty, don't suspect the argument position first. An eBPF program can't take a page fault when it reads user memory, so if that page isn't mapped into the process's page tables yet (even when the file's contents are already in the page cache), the read fails and `str()` returns an empty string. My first version of the sample had no `printf`, so `handle_order` never read `sku` itself, the page holding those strings was never touched, and every line said `sku=`. With the `printf` added it worked. In real programs the caller has usually just used the argument, so you rarely hit this.

### Latency and return values

Record the time on entry, subtract it on return, and you have the function's latency distribution. In a uretprobe, `retval` is the return value:

```bash
sudo bpftrace -e '
uprobe:./orders:handle_order { @start[tid] = nsecs; }
uretprobe:./orders:handle_order /@start[tid]/ {
    @ms = hist((nsecs - @start[tid]) / 1000000);
    @ret[(int32)retval] = count();
    delete(@start[tid]);
}'
```

Press Ctrl-C to print:

```text
@ms:
[0]                   14 |@@@                                                 |
[1]                   18 |@@@                                                 |
[2, 4)                45 |@@@@@@@@@                                           |
[4, 8)                66 |@@@@@@@@@@@@@@                                      |
[8, 16)              237 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[16, 32)             212 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@      |
[32, 64)               8 |@                                                   |
[64, 128)              1 |                                                    |
[128, 256)             1 |                                                    |

@ret[-1]: 134
@ret[0]: 468
@start[118]: 82587709380
```

Read the buckets with care: `hist()` uses powers of two, so the buckets widen as they go. `[8, 16)` alone covers 8 of the 20 possible sleep values and `[16, 32)` covers the 4 from 16 to 19, so even on real hardware about 60% of calls would land between 8 and 32 ms. The emulated VM shows up elsewhere: `usleep()` tends to oversleep, so `[16, 32)` holds 35% of calls instead of the expected 20%, and 10 calls took over 32 ms. About 22% of orders were rejected, close to the 2 in 10 you'd expect from rejecting quantities of 9 and 10.

A few details:

- **Don't drop the `(int32)` cast.** `retval` is an unsigned 64-bit value and the function returns a 32-bit `int`, so without the cast `-1` shows up as `4294967295`.
- **Key on `tid`.** The same function can run in several threads at once; keying by thread is what pairs each entry with its return.
- **Keep the `/@start[tid]/` filter.** The two probes aren't attached at the same instant, so if the uretprobe goes live first, a call can return without an entry time; `@start[tid]` then reads as 0 and you get one enormous latency. Calls that were already inside the function when you attached aren't the problem: the return address is rewritten at entry, so they never fire the uretprobe at all.
- When it exits, bpftrace prints every map that wasn't cleaned up, hence the `@start[118]` line at the end: a call that was still in progress at Ctrl-C.

### One process only

`-p PID` traces a single process. In this run the two `orders` processes had PIDs 119 and 120:

```bash
sudo bpftrace -p 119 -e 'uprobe:./orders:handle_order { @[pid] = count(); }'
```

```text
Attaching 1 probe...
@[119]: 140
```

The other `orders` process no longer appears. On a production machine this is the simplest way to cut overhead: `-p` hands the PID to the kernel, which then places the breakpoint only in that process, so other processes never trap at all. A `/pid == 119/` filter in the script is different: every process still hits the breakpoint, and the eBPF program merely records nothing, so the overhead stays the same.

I checked this in the VM. In another run, with the two processes at PIDs 117 and 118, I read the first byte of `handle_order` in each while tracing: normally it's `0xf3` (the start of an `endbr64` instruction), and with a breakpoint it becomes `0xcc` (`int3`). With `-p 117` only process 117 showed `0xcc`; with a `/pid == 117/` filter, both did.

## 5. Shared libraries: libc and OpenSSL

Library functions are uprobe targets too. bpftrace finds libraries by short name, so `libc` resolves to `/lib/x86_64-linux-gnu/libc.so.6`. For example, the sizes a Python process (PID 126, the test script from section 6) asks `malloc()` for:

```bash
sudo bpftrace -p 126 -e 'uprobe:libc:malloc { @bytes = hist(arg0); }'
```

```text
@bytes:
[32, 64)              10 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@         |
[64, 128)              5 |@@@@@@@@@@@@@@@@@@@@@                               |
[128, 256)             0 |                                                    |
[256, 512)             0 |                                                    |
[512, 1K)             12 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[1K, 2K)               0 |                                                    |
[2K, 4K)               0 |                                                    |
[4K, 8K)               0 |                                                    |
[8K, 16K)              0 |                                                    |
[16K, 32K)             0 |                                                    |
[32K, 64K)             6 |@@@@@@@@@@@@@@@@@@@@@@@@@@                          |
[64K, 128K)            0 |                                                    |
[128K, 256K)           0 |                                                    |
[256K, 512K)           0 |                                                    |
[512K, 1M)             5 |@@@@@@@@@@@@@@@@@@@@@                               |
```

There are only a few dozen calls. Python's own allocator, pymalloc, handles objects of 512 bytes or less, so what reaches `malloc()` is mostly larger blocks, plus the few places in the interpreter that call `malloc()` directly.

`-p` matters especially here: nearly every process on the machine maps `libc.so.6`, and without it every `malloc()` in every process traps into the kernel.

A process in a container uses the libraries in its image, not the files on the host. Either target it with `-p`, or spell out the container's path from the host through `/proc/PID/root`, for example `uprobe:/proc/1234/root/usr/lib/x86_64-linux-gnu/libc.so.6:malloc`.

### TLS plaintext before encryption

On the wire HTTPS is encrypted, and tcpdump only captures ciphertext. But when a program hands data to OpenSSL's `SSL_write()`, the data is still plaintext, and when `SSL_read()` returns, it has already been decrypted. Put uprobes on those two functions and you see the content before encryption and after decryption.

In the VM I ran a small HTTPS server in Python and requested it with curl, sending an `Authorization` header:

```bash
sudo BPFTRACE_MAX_STRLEN=200 bpftrace -e '
uprobe:libssl:SSL_write, uprobe:libssl:SSL_write_ex {
    printf("%s %s: %s\n", comm, probe, str(arg1, arg2));
}'
```

```text
Attaching 2 probes...
curl uprobe:/lib/x86_64-linux-gnu/libssl.so.3:SSL_write: GET / HTTP/1.1
Host: 127.0.0.1:8443
User-Agent: curl/8.5.0
Accept: */*
Authorization: Bearer s3cr3t-token
python3 uprobe:/lib/x86_64-linux-gnu/libssl.so.3:SSL_write_ex: HTTP/1.0 200 OK
Server: SimpleHTTP/0.6 Python/3.12.3
Date: Thu, 05 Nov 2026 07:43:15 GMT
Content-type: text/html
Content-Length: 18
Last-Modified: Thu, 05 Nov 2026 07:40:41 GMT
python3 uprobe:/lib/x86_64-linux-gnu/libssl.so.3:SSL_write_ex: hello from the vm
```

The token in the request header is right there, and so is the server's response. Two things to note:

- curl calls `SSL_write`, while Python calls `SSL_write_ex`; probe only one and you miss half the traffic. The read side is the same, with `SSL_read` and `SSL_read_ex`.
- bpftrace reads only 64 bytes of a string by default. In 0.20, raise it with `BPFTRACE_MAX_STRLEN` (200 here). The old name `BPFTRACE_STRLEN` still works but prints a deprecation warning.

Reading takes one more step. When `SSL_read()` is called its buffer is still empty, so save the buffer address on entry and read it on return, using the byte count it returned:

```bash
sudo BPFTRACE_MAX_STRLEN=200 bpftrace -e '
uprobe:libssl:SSL_read { @buf[tid] = arg1; }
uretprobe:libssl:SSL_read /@buf[tid]/ {
    if ((int32)retval > 0) {
        printf("%s read %d bytes: %s\n", comm, retval, str(@buf[tid], retval));
    }
    delete(@buf[tid]);
}'
```

```text
Attaching 2 probes...
curl read 185 bytes: HTTP/1.0 200 OK
Server: SimpleHTTP/0.6 Python/3.12.3
Date: Thu, 05 Nov 2026 07:43:29 GMT
Content-type: text/html
Content-Length: 18
Last-Modified: Thu, 05 Nov 2026 07:40:41 GMT
curl read 18 bytes: hello from the vm
```

This only works for programs **dynamically linked against the system's OpenSSL**. Go's `crypto/tls`, programs that statically link BoringSSL (Envoy, Chrome), Rust programs using rustls and Java's own TLS implementation never go through `libssl.so`, and each needs probes on its own functions. BCC's `sslsniff` is the complete version of this idea, covering OpenSSL, GnuTLS and NSS.

Seen from the other side, this also means that anyone who can load eBPF programs on a machine can read every process's plaintext traffic and key material. Manage `CAP_BPF`, `CAP_PERFMON` and `CAP_SYS_ADMIN` as if they were root.

## 6. USDT: probes the program defines

The `DTRACE_PROBE3(orders, shipped, id, sku, qty)` line in the sample is a USDT probe, with provider `orders` and name `shipped`:

```bash
sudo bpftrace -l 'usdt:./orders:*'
```

```text
usdt:./orders:orders:shipped
```

Quantity shipped per product:

```bash
sudo bpftrace -e 'usdt:./orders:orders:shipped { @qty[str(arg1)] = sum(arg2); }'
```

```text
Attaching 1 probe...
@qty[apple]: 262
@qty[cherry]: 400
@qty[banana]: 494
```

Compared with a uprobe, a USDT probe's location and arguments are chosen by the developer: rename the function, split it or let it be inlined, and the probe is still there. Rejected orders never reach `shipped`, so this counts what actually shipped, a piece of business meaning that a uprobe on the function's entry can't give you.

### Python's USDT probes

Many runtimes and databases ship USDT probes, provided they were built with support turned on (usually `--enable-dtrace` or `--with-dtrace`). Python 3.12 on Ubuntu 24.04 has these:

```bash
sudo bpftrace -l 'usdt:/usr/bin/python3.12:*'
```

```text
usdt:/usr/bin/python3.12:python:audit
usdt:/usr/bin/python3.12:python:gc__done
usdt:/usr/bin/python3.12:python:gc__start
usdt:/usr/bin/python3.12:python:import__find__load__done
usdt:/usr/bin/python3.12:python:import__find__load__start
```

The Python documentation also describes `function__entry`, `function__return` and `line` probes. This build doesn't have them, so tracing individual Python functions needs another approach.

The `audit` probe corresponds to Python's audit hooks (PEP 578): sensitive operations such as opening files, making connections and starting subprocesses raise an audit event, and `arg0` is the event name. My test script opens a file, connects to a local port and runs a subprocess once a second:

```bash
sudo bpftrace -p 126 -e 'usdt:/usr/bin/python3.12:python:audit { @[str(arg0)] = count(); }'
```

```text
Attaching 1 probe...
@[open]: 6
@[socket.connect]: 6
@[socket.__new__]: 6
@[socket.getaddrinfo]: 6
@[subprocess.Popen]: 6
```

Without changing a line of Python, you know what a process opened, where it connected and what it started. These probes use semaphores: Python only prepares the arguments when a tracer has bumped the probe's counter, so untraced they cost almost nothing. bpftrace handles the semaphores for you; in my tests it also saw events from every Python process that was already running when I left out `-p`.

`gc__start` and `gc__done` measure how long each garbage collection paused the process:

```bash
sudo bpftrace -p 126 -e '
usdt:/usr/bin/python3.12:python:gc__start { @start[tid] = nsecs; }
usdt:/usr/bin/python3.12:python:gc__done /@start[tid]/ {
    @us = hist((nsecs - @start[tid]) / 1000);
    delete(@start[tid]);
}'
```

```text
@us:
[64, 128)           1516 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[128, 256)            20 |                                                    |
[256, 512)             0 |                                                    |
[512, 1K)            116 |@@@                                                 |
[1K, 2K)              12 |                                                    |
[2K, 4K)              26 |                                                    |
[4K, 8K)               8 |                                                    |
[8K, 16K)              3 |                                                    |
[16K, 32K)             7 |                                                    |
[32K, 64K)             6 |                                                    |
[64K, 128K)            2 |                                                    |
```

Most are small young-generation collections under 128 µs. My script calls `gc.collect()` explicitly once a second, and the handful of pauses lasting tens of milliseconds at the tail are mostly those full collections; each loop also allocates 200,000 objects, which can trigger automatic collections of the older generations too (all inflated by the emulator). Latency spikes in Python services often hide in pauses like these.

Other common sources of USDT probes:

- **PostgreSQL** built with `--enable-dtrace`: probes for queries, locks, transactions and more.
- **MySQL** before 8.0.
- **The HotSpot JVM**: probes for GC, class loading and threads are there by default; the method, allocation and lock probes are switched on with `-XX:+DTraceMethodProbes`, `-XX:+DTraceAllocProbes` and `-XX:+DTraceMonitorProbes`. The old catch-all `-XX:+ExtendedDTraceProbes` was deprecated in JDK 19 and has had no effect since JDK 20.
- **glibc** itself: besides `setjmp`, `longjmp` and a set of allocator probes, it has thread and lock probes such as `pthread_create`, `mutex_entry`, `mutex_acquired` and `cond_wait`, handy for lock contention.

`readelf -n BINARY | grep -A3 stapsdt` tells you whether a file has any.

## 7. Go programs: watch the entry, leave the return alone

This Go program calls `handle()` from a new goroutine, rests 50 ms, then starts the next one, and the recursion in `deep()` keeps growing each new goroutine's stack:

```go
// gosvc.go
package main

import (
	"fmt"
	"time"
)

//go:noinline
func deep(n int) int {
	var pad [512]byte
	pad[n%512] = byte(n)
	if n == 0 {
		return int(pad[0])
	}
	return deep(n-1) + int(pad[n%512])
}

//go:noinline
func handle(id int, qty int) int {
	return qty*2 + deep(200)%2 // deep() makes the goroutine's stack grow
}

func main() {
	for id := 1; ; id++ {
		done := make(chan int)
		go func() { done <- handle(id, id%10) }()
		r := <-done
		if id%20 == 0 {
			fmt.Println("handled", id, r)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
```

Build it with `go build -o gosvc gosvc.go` and run it. `go build` keeps the symbol table by default (unless you pass `-ldflags="-s -w"`), and function names include the package:

```bash
sudo bpftrace -l 'uprobe:./gosvc:main.*'
```

```text
uprobe:./gosvc:main.deep
uprobe:./gosvc:main.handle
uprobe:./gosvc:main.main
uprobe:./gosvc:main.main.func1
```

Reading arguments needs care. Since Go 1.17, amd64 uses Go's own register calling convention, with integer arguments in `rax`, `rbx`, `rcx`, `rdi`, `rsi`, `r8` and so on. That differs from C, so `arg0` isn't the first argument. Read the registers directly with `reg()`:

```bash
sudo bpftrace -e 'uprobe:./gosvc:main.handle { printf("id=%d qty=%d\n", reg("ax"), reg("bx")); }'
```

```text
Attaching 1 probe...
id=3259 qty=9
id=3260 qty=0
id=3261 qty=1
```

**Never put a uretprobe on a Go function.** Goroutine stacks start small, and when one runs out the runtime copies the whole stack to a bigger block. Both that copy and the garbage collector's stack scan walk the stack frame by frame through the return addresses. A return address rewritten by a uretprobe points into a trampoline page the kernel maps into the process (shown as `[uprobes]` in `/proc/PID/maps`). It belongs to no Go function, the runtime can't find the frame, and the process crashes. I attached a uretprobe to `main.handle` and the service died shortly after tracing started:

```text
runtime: g 1317: unexpected return pc for main.handle called from 0xffffffffffe000
stack: frame={sp:0xc00006bf98, fp:0xc00006bfb0} stack=[0xc00006b000,0xc00006c000)
```

`0xffffffffffe000` is that trampoline page, at the very top of the address space: with a uretprobe attached, the `[uprobes]` line in `/proc/PID/maps` reads `ffffffffffe000-fffffffffff000`. It's this high because the VM's CPU uses 5-level page tables; on a typical machine it's around `0x7fffffffe000`.

The usual workaround is to skip the uretprobe and put an ordinary uprobe on each `ret` instruction in the function (find the offsets with `objdump -d`), where the return value is in `rax`. Ubuntu 24.04's bpftrace 0.20.2, though, was built without offset checking, so it rejects `uprobe:./gosvc:main.handle+0x3d` and a raw address alike, even with `--unsafe`:

```text
ERROR: Can't check if uprobe is in proper place (compiled without (k|u)probe offset support): ./gosvc:main.handle+61
```

To see a Go function's return value on this setup, you need a bpftrace you built yourself, or a libbpf program that computes the offsets. Also, a goroutine can be moved to another thread in the middle of a function, so pairing entry and return by `tid` isn't reliable in Go.

JIT runtimes such as Java and Node.js are harder still: hot code is generated at run time, with no fixed file and offset for a uprobe to attach to. For those you rely on the runtime's own USDT probes, or on sampling with a perf map.

## 8. Before you use it in production

- **Estimate the call rate first.** Overhead is proportional to hits. Use `count()` to see the rate; counting costs a trip into the kernel per hit too, so add `-p` here as well and run it for just one second. `interval:s:1 { exit(); }` exits after a second and prints the count:

  ```bash
  sudo bpftrace -p 119 -e 'uprobe:./orders:handle_order { @calls = count(); } interval:s:1 { exit(); }'
  ```

  At tens of thousands of calls a second or more, shorten the run or pick a function that's called less often.
- **Probes don't follow a replaced binary.** A uprobe is bound to the file that existed when you attached. While tracing, I replaced `orders` with `cp` and `mv` and started a new process: the counts showed only the two old processes, and the new one never appeared. After deploying a new version, attach again.
- **Function names aren't an interface.** In the next release a function may be renamed, inlined or removed. A rename or removal is the easy case, because bpftrace refuses to start. The hard case is a function that still exists but is now inlined at some call sites, or reached by different paths for different reasons: the script still runs and the numbers are quietly wrong. Use USDT where it exists; with uprobes, sanity-check the numbers after every upgrade.
- **Strings can come back empty.** The reason is in section 4: eBPF can't read memory the traced process hasn't touched yet.
- **Mind the data.** If you can attach a uprobe, you can read any of the process's memory, including TLS plaintext, passwords and keys. Treat the trace output as sensitive too.

## 9. Summary

- A uprobe puts a breakpoint in a file, and every process using that file hits it; narrow it with `-p` and estimate the rate with `count()` first.
- Read arguments from `arg0` onwards, or `args.NAME` with debug info; read return values from `retval` in a uretprobe, casting signed ones first.
- Library functions work the same way: `malloc()` sizes, OpenSSL plaintext before encryption.
- USDT probes are stable probes the program defines itself, and Python's `audit` and GC probes work without touching the code.
- Go passes arguments in registers and must never get a uretprobe; JIT-compiled code can't be uprobed.

## 10. Links

**Documentation**

- [bpftrace manual: probe types](https://github.com/bpftrace/bpftrace/blob/master/man/adoc/bpftrace.adoc): syntax and limits for uprobe, uretprobe and usdt
- [Kernel docs: uprobe-based event tracing](https://docs.kernel.org/trace/uprobetracer.html)
- [SystemTap wiki: user-space probe implementation](https://sourceware.org/systemtap/wiki/UserSpaceProbeImplementation): the format of `sys/sdt.h` and `.note.stapsdt`
- [Python docs: instrumenting CPython with DTrace and SystemTap](https://docs.python.org/3/howto/instrumentation.html), and the [audit events table](https://docs.python.org/3/library/audit_events.html)
- [Go internal ABI specification](https://github.com/golang/go/blob/master/src/cmd/compile/abi-internal.md): the register order for arguments

**Tools**

- [BCC's sslsniff](https://github.com/iovisor/bcc/blob/master/tools/sslsniff.py): plaintext tracing for OpenSSL, GnuTLS and NSS
- bpftrace's own `/usr/sbin/sslsnoop.bt`, `ssllatency.bt` and `bashreadline.bt`, all ready-made uprobe examples

**This series**

- [Getting Started with eBPF](https://suzf.net/en/blog/posts/ebpf-getting-started/) and [Troubleshooting a Slow Linux Server with eBPF](https://suzf.net/en/blog/posts/ebpf-troubleshooting-playbook/)
