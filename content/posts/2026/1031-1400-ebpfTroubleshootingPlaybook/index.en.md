---
title: "Troubleshooting a Slow Linux Server with eBPF: A Symptom-by-Symptom Playbook"
slug: "ebpf troubleshooting playbook"
date: 2026-10-31T14:00:00+08:00
author: "Jeffrey Su"
description: "Which eBPF tool to run for which symptom: short-lived processes, CPU flame graphs, run queue latency, off-CPU time, disk and filesystem latency, TCP retransmits and drops, DNS, OOM kills and failing syscalls, with the flags that matter and how to read the output."
categories: ["Skills Matrix"]
tags: ["ebpf", "linux", "observability", "performance"]
toc: true
draft: false
---

The [first eBPF post](https://suzf.net/en/blog/posts/ebpf-getting-started/) covered what eBPF is, how programs get past the verifier and how to write one with libbpf. This one is the practical follow-up: a service is slow or a machine is misbehaving, and you want to know which tool to run, which flags matter and what the output is telling you.

It's organised by symptom. Each section starts from something you can see with the classic tools, names the eBPF tool that answers the next question, and says what to look for.

<!--more-->

All commands use the BCC tools from Ubuntu's `bpfcc-tools` package (version 0.29 here), which carry a `-bpfcc` suffix. On other distributions they usually live in `/usr/share/bcc/tools/` without the suffix. Every tool needs root. The ones that trace every event print until you press Ctrl-C; the ones that summarise take an interval and a count, like `vmstat`.

## 1. Find the resource first

eBPF tools answer narrow questions very precisely, so pick the question before you pick the tool. Spend a minute with the classic tools to see which resource is under pressure:

```bash
uptime                 # load average: rising, falling, steady?
vmstat 1               # r (run queue), b (blocked), si/so (swapping), us/sy/wa/st
mpstat -P ALL 1        # is one CPU pinned while the others idle?
iostat -xz 1           # r_await/w_await (latency), aqu-sz (queue), %util per disk
sar -n DEV,TCP,ETCP 1  # throughput, new connections, retransmits
free -m                # available memory, swap use
dmesg -T | tail        # OOM kills, disk errors, dropped packets
```

Then jump to the matching section:

| What you see | Go to |
|---|---|
| High CPU, but nothing stands out in `top` | [2. Short-lived processes](#2-cpu-is-busy-but-top-shows-nothing) |
| One process using a lot of CPU | [3. Where the CPU time goes](#3-a-process-is-burning-cpu-where-in-the-code) |
| Load average high, CPU not at 100% | [4. Waiting for a CPU](#4-load-is-high-but-the-cpu-isnt-full) |
| Slow requests, low CPU | [5. Off-CPU time](#5-slow-but-not-using-cpu-off-cpu-time) |
| `iostat` latency high or `wa` high | [6. Disk and filesystem](#6-disk-and-filesystem-latency) |
| Timeouts, slow connects, retransmits | [7. Network](#7-network-slow-connections-retransmits-and-drops) |
| OOM kills, swapping, cache misses | [8. Memory](#8-memory-oom-kills-reclaim-and-the-page-cache) |
| Something fails, but logs say nothing | [9. Errors](#9-something-fails-quietly) |

Two habits make every tool below safer and its output more useful:

- **Filter by process.** Most tools take `-p PID`. For a container, use the PID as the host sees it: `docker inspect -f '{{.State.Pid}}' <container>` or, on a Kubernetes node, `crictl inspect --output go-template --template '{{.info.pid}}' <container-id>`. The PID inside the container is a different number.
- **Bound the run.** Give summarising tools a duration, and stop event tracers after a few seconds on a busy machine. Every traced event costs a little CPU, and some events fire hundreds of thousands of times a second.

## 2. CPU is busy but top shows nothing

`top` samples every few seconds and shows processes that exist at that moment. A program that forks a hundred short-lived children a second (a health check calling `curl`, a cron job in a loop, a shell script spawning `grep | awk | sed` per line) can burn a whole CPU without any single process ever appearing in the list.

`execsnoop` prints every `exec()` as it happens, with the parent PID and arguments:

```bash
execsnoop-bpfcc -T          # add an HH:MM:SS column
execsnoop-bpfcc -T -x       # also show failed exec()s (missing binary, permissions)
execsnoop-bpfcc -P 1234     # only children of PID 1234
```

If the same command scrolls past many times a second, you've found it; `PPID` tells you who is starting it. Its counterpart `exitsnoop` shows processes as they die, with their age and exit code. `exitsnoop-bpfcc -x` shows only failures, which is the quickest way to catch a crash loop that a supervisor keeps restarting.

## 3. A process is burning CPU: where in the code?

When one process is clearly the consumer, the next question is which functions. `profile` samples stacks on every CPU at a fixed rate, and its folded output goes straight into a flame graph:

```bash
profile-bpfcc -F 99 -f -p 1234 30 > cpu.folded     # 99 Hz, folded stacks, 30 seconds
git clone https://github.com/brendangregg/FlameGraph
./FlameGraph/flamegraph.pl cpu.folded > cpu.svg
```

Open the SVG in a browser. Width is time on CPU: the widest towers are where to look, and the top edge of each tower is the function actually running. Use `-U` for user-space stacks only or `-K` for kernel only; a lot of kernel time under `sys_` frames usually means the program is making too many system calls rather than computing too much (`syscount-bpfcc -p 1234 -L` shows which ones, with their total time).

Stacks are only as good as the symbols. Native binaries need symbols that haven't been stripped and, for reliable user stacks, frame pointers. JIT runtimes need a perf map: start Node.js with `--perf-basic-prof`, and Java with `-XX:+PreserveFramePointer` plus an agent such as perf-map-agent. Without them you get a tower of `[unknown]`.

## 4. Load is high but the CPU isn't full

Load average counts tasks that are running *or waiting to run* (and on Linux, tasks in uninterruptible sleep too). When it's high but `mpstat` shows idle time, or latency is bad on a machine that looks only half busy, measure how long tasks wait for a CPU. That's **run queue latency**:

```bash
runqlat-bpfcc -m 10 1       # one 10-second histogram, in milliseconds
runqlat-bpfcc -P 10 1       # one histogram per process
runqslower-bpfcc -P 5000    # print every wait over 5 ms, and who was running instead
```

`runqlat` prints a histogram of the time between a task becoming runnable and it actually getting a CPU. On a healthy machine almost everything sits in the microsecond buckets. A tail reaching into milliseconds means tasks are queuing: too many runnable threads, work pinned to some CPUs while others sit idle, or a noisy neighbour. `runqslower -P` names the task that waited and the one that held the CPU meanwhile.

In containers also check the CPU limit. A container that hits its CFS quota is paused for the rest of the period, which shows up as latency with plenty of idle CPU on the host. On cgroup v2, `nr_throttled` and `throttled_usec` in the container's `cpu.stat` show how often and how long.

## 5. Slow but not using CPU: off-CPU time

If a request takes 800 ms and the process is on CPU for 20 ms of it, the rest is spent waiting: for a lock, the disk, the network, a sleep or another thread. CPU profiling can't see any of that. `offcputime` records the stack every time a thread leaves the CPU and adds up how long it stayed off:

```bash
offcputime-bpfcc -f -p 1234 30 > offcpu.folded
./FlameGraph/flamegraph.pl --color=io --title="Off-CPU time" --countname=us offcpu.folded > offcpu.svg
```

Now width is time *blocked*. Read the stacks from the bottom: the user frames say which code path waited, and the kernel frames at the top say on what. `futex_wait` is a lock or condition variable, `io_schedule` or `blk_` frames are disk I/O, `tcp_recvmsg` or `sk_wait_data` is waiting for the network, `do_nanosleep` is an explicit sleep. Idle worker threads waiting for work also show up as wide towers; they're normal, so look at the threads that serve the slow request.

Two flags cut the noise: `-m 1000` keeps only waits longer than 1 ms, and `--state 2` keeps only uninterruptible sleep (`TASK_UNINTERRUPTIBLE`, usually disk). Scheduler events are very frequent, so `offcputime` costs more than most tools here; keep runs short on busy production machines.

## 6. Disk and filesystem latency

`iostat` gives averages per disk. An average of 5 ms can be every I/O taking 5 ms or most taking 0.1 ms and a few taking 200 ms, and those need different fixes. `biolatency` shows the distribution:

```bash
biolatency-bpfcc -D -m 10 1     # one 10-second histogram per disk, in milliseconds
biolatency-bpfcc -Q -D 10 1     # include time queued in the OS, not just on the device
```

Two humps usually mean two kinds of I/O, such as small cached reads and large writes, or a device that is mostly fast with periodic stalls. Compare the numbers with what the device should do: local NVMe mostly stays under a millisecond, while network block storage such as EBS is in single-digit milliseconds. If `-Q` adds a lot on top, I/O is waiting in the OS queue, which means more requests are in flight than the device can serve.

To see who is doing the I/O, `biosnoop` prints each request with its process, direction, size and latency (`QUE(ms)` with `-Q`, `LAT(ms)` on the device). One caveat from its man page: the process name is whoever was running when the I/O was issued, so writes flushed later by the kernel often show up as a kernel worker rather than the program that wrote the data.

What the application feels is filesystem latency, which includes locks, page cache misses and the disk. The `*slower` tools trace operations at the filesystem level and print the slow ones with the file name:

```bash
ext4slower-bpfcc 10          # ext4 reads, writes, opens and fsyncs over 10 ms
xfsslower-bpfcc 10           # the same for XFS
cachestat-bpfcc 1            # page cache hits, misses and hit ratio every second
```

A slow `S` (fsync) row is a classic finding: a database or logger syncing on every write. A falling hit ratio in `cachestat` while reads get slower means the working set no longer fits in memory.

## 7. Network: slow connections, retransmits and drops

Network problems mostly show up as timeouts in someone else's logs. Start with which connections are slow to establish:

```bash
tcpconnlat-bpfcc 100      # outbound connects slower than 100 ms, with PID and remote address
tcplife-bpfcc -L 443      # every connection on local port 443: duration and KB sent/received
gethostlatency-bpfcc      # DNS lookups with their latency
```

A connect that takes just over one second, or three, is a retransmitted SYN: the first SYN or its reply was lost, often because a listen queue overflowed or a firewall dropped it. `tcplife` is a cheap way to see connection churn (thousands of sub-millisecond connections are a missing connection pool) and which peers move the most data. `gethostlatency` only sees lookups that go through the C library's `getaddrinfo()`; Go programs using the pure-Go resolver bypass it, so check those at the DNS server or with `tcpdump port 53`.

For established connections, look at retransmits and drops:

```bash
tcpretrans-bpfcc          # each retransmit: addresses, ports, TCP state
tcpretrans-bpfcc -c       # count retransmits per flow instead, printed on Ctrl-C
tcpdrop-bpfcc             # packets the kernel dropped, each with the kernel stack that dropped it
tcpsynbl-bpfcc            # SYN backlog length when each SYN arrives, one histogram per backlog limit
```

`tcpretrans` names the flows that are losing packets. If they all go to one peer or one subnet, the problem is on that path; if they're spread everywhere, look at the local NIC, the host's bandwidth limit or the instance type. Its `PID` column is usually 0, because most retransmits fire from a kernel timer, not from the process.

`tcpdrop` prints the kernel stack for each dropped packet, and the function names there tell you which check discarded it: a full accept queue, a socket buffer limit, a failed checksum, a netfilter rule. On recent kernels it uses the `skb:kfree_skb` tracepoint, which records a drop reason. If `tcpsynbl` shows the backlog at its limit, the application isn't calling `accept()` fast enough or the `listen()` backlog is too small. `nstat -az TcpExtListenOverflows` confirms it.

## 8. Memory: OOM kills, reclaim and the page cache

```bash
oomkill-bpfcc             # each OOM kill: victim, the task that triggered it, load averages
drsnoop-bpfcc -p 1234     # direct reclaim events and how long they stalled the process
memleak-bpfcc -p 1234 30  # outstanding allocations by stack, every 30 seconds
```

`dmesg` also records OOM kills, but `oomkill` shows which task was allocating when it happened, which is often not the one that got killed. `drsnoop` explains a particular kind of latency spike: when free memory runs low, a process asking for memory has to reclaim pages itself before it can continue, and the tool prints how long each of those stalls lasted. `memleak` follows every `malloc()` and `free()` to find allocations that are never freed. It's useful when a process grows steadily, but its overhead is high, so attach it briefly or on a test instance.

## 9. Something fails quietly

Programs often handle errors by retrying or falling back without logging anything. Failed system calls show what they ran into:

```bash
opensnoop-bpfcc -x -p 1234      # only failed opens: missing config files, wrong paths, EACCES
syscount-bpfcc -x -P            # failed syscalls counted per process
syscount-bpfcc -e ENOSPC        # only calls that failed with ENOSPC
execsnoop-bpfcc -x              # failed exec()s
```

`opensnoop -x` is the fastest way to find out which config file a program is *actually* looking for, and in which order it searches. A process that fails thousands of calls a second with `EAGAIN` is usually spinning on a non-blocking socket.

## 10. When no tool fits

The BCC suite also has general-purpose tools that trace any function you name:

```bash
funclatency-bpfcc -m -p 1234 c:fsync                          # histogram of libc fsync() time
funclatency-bpfcc -u vfs_read                                 # kernel vfs_read() latency, in microseconds
trace-bpfcc 'r::do_sys_openat2 (retval < 0) "open failed: %d", retval'   # print failing opens
argdist-bpfcc -p 1234 -C 'p:c:write(int fd):int:fd'           # count write() calls per file descriptor
```

The prefix says where the function lives: no prefix or `p::` for kernel functions, `r::` for their return, `c:` for the C library, or a path to any binary or library. Kernel function names change between versions (on 6.x kernels opens go through `do_sys_openat2`, which older tutorials call `do_sys_open`), so check with `bpftrace -l 'kprobe:do_sys_open*'` first. Tracepoints such as `syscalls:sys_enter_openat` are the stable alternative.

For anything that needs custom aggregation, write a bpftrace one-liner. For example, the distribution of bytes returned by `read()` for each process:

```bash
bpftrace -e 'tracepoint:syscalls:sys_exit_read /args.ret > 0/ { @bytes[comm] = hist(args.ret); }'
```

## 11. Overhead and safety

These tools are designed to be run on production machines, and the verifier guarantees they can't crash the kernel. They still cost something per event, and that's the thing to manage:

- **Cheap**: tools that hook rare events, such as `execsnoop`, `tcpconnlat`, `tcpretrans`, `oomkill` and `ext4slower` with a threshold.
- **Moderate**: summaries of frequent events aggregated in the kernel, such as `biolatency`, `runqlat` and `profile` at 99 Hz.
- **Expensive**: anything that hooks every scheduler switch, every allocation or every syscall and sends events to user space: `offcputime`, `memleak`, `syscount` on a very busy process, `opensnoop` without a filter.

Start with the cheap ones, filter by PID, and give the rest a duration. When a tool exits it unloads its programs; `bpftool prog list` shows anything that is still attached.

## 12. Cheat sheet

| Symptom | First tool | Then |
|---|---|---|
| CPU busy, no culprit in `top` | `execsnoop -T` | `exitsnoop -x` |
| One process using CPU | `profile -F 99 -f -p PID` → flame graph | `syscount -p PID -L` |
| Latency with idle CPU | `runqlat -m 10 1` | `runqslower -P`, cgroup `cpu.stat` |
| Slow, low CPU | `offcputime -f -p PID` → flame graph | the matching section below |
| Disk slow | `biolatency -D -m 10 1` | `biosnoop`, `ext4slower 10` |
| Reads slower over time | `cachestat 1` | `free -m`, memory limits |
| Slow or failing connects | `tcpconnlat 100` | `tcpsynbl`, `nstat` |
| Timeouts on established connections | `tcpretrans -c` | `tcpdrop` |
| DNS slow | `gethostlatency` | resolver config |
| Process killed | `oomkill` | `drsnoop`, `memleak` |
| Silent failures | `opensnoop -x`, `syscount -x -P` | `trace` |

For the background on how these tools work, and how to write your own when none of them fit, see [Getting Started with eBPF](https://suzf.net/en/blog/posts/ebpf-getting-started/). Brendan Gregg's book *BPF Performance Tools* covers each of them in depth, and every BCC tool ships with a man page and an `_example.txt` file of annotated output.
