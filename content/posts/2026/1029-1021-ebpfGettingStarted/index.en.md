---
title: "Getting Started with eBPF: Tracing Linux Without Rebooting"
slug: "ebpf getting started"
date: 2026-10-29T10:21:21+08:00
author: "Jeffrey Su"
description: "What eBPF is, how programs pass the verifier, the main hook points, bpftrace and BCC tools, a libbpf + CO-RE example, and kernel and permission requirements."
categories: ["Skills Matrix"]
tags: ["ebpf", "linux", "observability"]
toc: true
draft: false
---

CPU spikes on a production box, disk latency jitters, a process quietly opens connections to the internet. The old options were to add logging and redeploy, or to write a kernel module and risk a panic. eBPF lets you attach a small, verified program to almost any kernel event, collect data on the spot and unload it when you are done: no kernel patch, no reboot, no change to the application. This post goes from how it works to hands-on use: ready-made tools first, then an eBPF program of your own.

<!--more-->

## 1. What eBPF is

eBPF (extended Berkeley Packet Filter) is a **sandboxed virtual machine inside the Linux kernel**. You write a program in restricted C (or a higher-level language such as bpftrace), compile it to eBPF bytecode and hand it to the kernel. The kernel first proves the program is safe, then compiles it to native instructions and runs it on the event you chose: a system call, a kernel function, a packet arriving at the NIC, a function in a user-space program.

The name comes from BPF, the 1992 packet filter behind tcpdump, but eBPF has long outgrown packet filtering. What matters is how it differs from a kernel module:

| | Kernel module | eBPF program |
|---|---|---|
| Safety | One NULL pointer can crash the kernel | The verifier proves before loading that it cannot crash or loop forever |
| Compatibility | Tied to one kernel version, rebuild for each | With BTF + CO-RE, one build runs on many kernels |
| Deployment | `insmod`, hard to back out of a mistake | By default unloaded when the loading process exits (unless pinned in `/sys/fs/bpf`) |
| Capability | Unrestricted | Can only call the helpers the kernel provides |

In short, eBPF gives up some power in exchange for being something you **dare to use** in production.

## 2. How an eBPF program gets running

```text
 C / bpftrace source
        │  clang -target bpf
        ▼
  eBPF bytecode (.o)
        │  bpf() syscall
        ▼
 ┌──────────── kernel ────────────┐
 │  verifier: checks every path   │
 │        │                       │
 │        ▼                       │
 │  JIT: x86 / arm64 instructions │
 │        │                       │
 │        ▼                       │
 │  attached to a hook (kprobe,   │──runs when the
 │  XDP, ...)                     │  event fires
 │        │                       │
 │        ▼                       │
 │  maps / ring buffer            │
 └────────┼───────────────────────┘
          ▼
   user space reads the results
```

The core ideas:

- **Verifier**: at load time it walks every execution path of the program and confirms it never accesses memory out of bounds, never reads uninitialized values, always terminates and only calls allowed helpers. If not, the load is rejected. This is the reason eBPF is safe enough for production.
- **JIT**: once verified, the bytecode is compiled to native instructions, so it runs at close to native speed.
- **Hook**: the event the program is attached to decides when it runs and what context it sees.
- **Map**: a key-value store shared between the kernel and user space, and between eBPF programs: hash, array, per-CPU array, LRU, ring buffer and more. A program has no global state of its own, so counters, histograms and event queues all live in maps.
- **Helper functions**: the only way a program talks to the kernel, for example `bpf_get_current_pid_tgid()`, `bpf_probe_read_kernel()`, `bpf_ringbuf_submit()`.

## 3. Common hook points

| Hook | Fires on | Stability | Typical use |
|---|---|---|---|
| `tracepoint` | Static trace points built into the kernel | Stable across versions | Syscalls, scheduler, block I/O |
| `kprobe` / `kretprobe` | Entry / return of any kernel function | Unstable, functions get renamed or inlined | Kernel paths without a tracepoint |
| `fentry` / `fexit` | Kernel function entry / return (5.5+) | Same as kprobe, but cheaper; fexit sees both arguments and return value | Replacement for kprobe |
| `uprobe` / `uretprobe` | Any function in a user-space program | Changes with the application | OpenSSL, databases, Go/Java apps |
| `USDT` | Static probes built into an application | Stable | MySQL, PostgreSQL, Python, JVM |
| `perf_event` | Timed sampling, hardware counters | Stable | CPU flame graphs |
| `XDP` | Packet received by the driver, before an skb exists | Stable | DDoS mitigation, load balancing |
| `tc` | Traffic control, ingress / egress | Stable | Container networking, policy |
| `cgroup` / `LSM` | Socket and device operations in a cgroup / security hooks (5.7+) | Stable | Network policy, runtime security |

Rule of thumb: **use a tracepoint when one exists**, and fall back to fentry or kprobe when it does not. A kprobe traces a kernel-internal function, and after a kernel upgrade the symbol may be gone. Keep that in mind before building monitoring on one.

## 4. Start with bpftrace

To answer "what is happening on this box right now", bpftrace is the handiest tool. Its syntax is like awk: `probe /filter/ { action }`. On Ubuntu, `apt install bpftrace`; it runs as root.

```bash
# Who is starting new processes (every execve)
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_execve { printf("%-6d %-16s %s\n", pid, comm, str(args.filename)); }'

# Who is opening which file
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args.filename)); }'

# Syscall count per process, printed on Ctrl-C
sudo bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'

# vfs_read latency distribution (histogram in microseconds)
sudo bpftrace -e 'kprobe:vfs_read { @start[tid] = nsecs; }
  kretprobe:vfs_read /@start[tid]/ { @us = hist((nsecs - @start[tid]) / 1000); delete(@start[tid]); }'

# Which processes open TCP connections
sudo bpftrace -e 'kprobe:tcp_connect { @[comm] = count(); }'

# Sample user stacks of PID 1234 at 99 Hz (input for a flame graph)
sudo bpftrace -e 'profile:hz:99 /pid == 1234/ { @[ustack] = count(); }'
```

A few notes:

- Names starting with `@` are maps. `@[comm] = count()` counts by process name, and bpftrace prints every map when the program ends.
- `args.filename` is a tracepoint argument. Older bpftrace releases (such as 0.14 in Ubuntu 22.04) need `args->filename`. To see a tracepoint's arguments, run `sudo bpftrace -lv 'tracepoint:syscalls:sys_enter_openat'`.
- `sudo bpftrace -l 'tracepoint:syscalls:*'` lists available probes, wildcards included.
- Sampling at 99 Hz rather than 100 avoids running in lockstep with other periodic work, which would skew the sample.

## 5. Ready-made tools: BCC and bpftrace tools

Many common questions already have a tool. On Ubuntu, install `bpfcc-tools`; the commands carry a `-bpfcc` suffix (other distributions usually put them in `/usr/share/bcc/tools/` without the suffix):

| Tool | The question it answers |
|---|---|
| `execsnoop-bpfcc` | Who keeps starting short-lived processes? (first stop when CPU is high but `top` shows no culprit) |
| `opensnoop-bpfcc` | Which files are processes opening, and which opens fail? |
| `biolatency-bpfcc` | Block I/O latency distribution |
| `biosnoop-bpfcc` | Process, size and latency of every disk I/O |
| `tcplife-bpfcc` | Start, end and bytes of every TCP connection |
| `tcpretrans-bpfcc` | Which connections are retransmitting |
| `runqlat-bpfcc` | How long tasks wait on the run queue (CPU contention) |
| `profile-bpfcc` | CPU sampling, output ready for a flame graph |
| `oomkill-bpfcc` | Who the OOM killer killed and who was allocating at the time |

The bpftrace package ships a similar set of tools written as bpftrace scripts. On Ubuntu they live in `/usr/sbin/` with a `.bt` suffix, for example `execsnoop.bt`, `biolatency.bt` and `tcpretrans.bt`. They are good bpftrace examples too, worth reading before you write your own scripts.

For performance work, Brendan Gregg's ["60-second analysis"](https://www.brendangregg.com/Articles/Netflix_Linux_Perf_Analysis_60s.pdf) is a good order: use the classic tools (`uptime`, `vmstat`, `iostat`) to tell whether it is CPU, memory, disk or network, then drill down with the matching eBPF tool. The follow-up post, [Troubleshooting a Slow Linux Server with eBPF](https://suzf.net/en/blog/posts/ebpf-troubleshooting-playbook/), walks through that symptom by symptom: which tool to run, which flags matter and how to read the output.

## 6. Write your own: libbpf + CO-RE

bpftrace is for ad-hoc investigation. For a long-running agent you usually write the kernel side in C and load it with libbpf. Below is a minimal execsnoop: every time a process successfully execs, it sends the PID, parent PID and new process name to user space through a ring buffer.

### 6.1 Setup

```bash
sudo apt install clang libbpf-dev linux-tools-common linux-tools-$(uname -r)

# Check the kernel has BTF (required for CO-RE)
ls /sys/kernel/btf/vmlinux

# Dump every type of the running kernel, in place of the kernel headers
bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
```

### 6.2 Kernel side

```c
// execsnoop.bpf.c
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

struct event {
	u32 pid;
	u32 ppid;
	char comm[16];
};

struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 256 * 1024);
} events SEC(".maps");

SEC("tracepoint/sched/sched_process_exec")
int handle_exec(void *ctx)
{
	struct task_struct *task = (struct task_struct *)bpf_get_current_task();
	struct event *e;

	e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
	if (!e)
		return 0;

	e->pid = bpf_get_current_pid_tgid() >> 32;
	e->ppid = BPF_CORE_READ(task, real_parent, tgid);
	bpf_get_current_comm(&e->comm, sizeof(e->comm));

	bpf_ringbuf_submit(e, 0);
	return 0;
}
```

- `SEC(...)` tells libbpf where to attach the function, here the `sched:sched_process_exec` tracepoint. It fires after exec succeeds, when the process name is already the new program's. On `syscalls:sys_enter_execve` the exec has not happened yet, and `bpf_get_current_comm()` returns the caller's name (usually `bash`).
- `LICENSE` is required; many helpers are only available to GPL-compatible programs.
- `bpf_ringbuf_reserve` can fail when the buffer is full. You **must check the result**, or the verifier rejects the program.
- `BPF_CORE_READ(task, real_parent, tgid)` is CO-RE at work: it records the intent "read `task_struct.real_parent.tgid`", and at load time libbpf fixes up the field offsets from the target kernel's BTF. `task_struct` is laid out differently on each kernel, and the same `.o` still works.
- The upper 32 bits of `bpf_get_current_pid_tgid()` are what user space calls the PID (the kernel calls it tgid); the lower 32 bits are the thread ID.

### 6.3 User-space side

```c
// execsnoop.c
#include <errno.h>
#include <stdio.h>
#include <signal.h>
#include <bpf/libbpf.h>
#include "execsnoop.skel.h"

struct event {
	unsigned int pid;
	unsigned int ppid;
	char comm[16];
};

static volatile sig_atomic_t stop;
static void on_sigint(int sig) { stop = 1; }

static int on_event(void *ctx, void *data, size_t size)
{
	const struct event *e = data;
	printf("%-8u %-8u %s\n", e->pid, e->ppid, e->comm);
	return 0;
}

int main(void)
{
	struct execsnoop_bpf *skel;
	struct ring_buffer *rb = NULL;
	int err;

	skel = execsnoop_bpf__open_and_load();   /* open + verify + load */
	if (!skel)
		return 1;
	err = execsnoop_bpf__attach(skel);       /* attach to the tracepoint */
	if (err)
		goto out;

	rb = ring_buffer__new(bpf_map__fd(skel->maps.events), on_event, NULL, NULL);
	if (!rb) {
		err = -1;
		goto out;
	}

	signal(SIGINT, on_sigint);
	printf("%-8s %-8s %s\n", "PID", "PPID", "COMM");
	while (!stop) {
		err = ring_buffer__poll(rb, 100);
		if (err == -EINTR) { err = 0; break; }
		if (err < 0) break;
	}
out:
	ring_buffer__free(rb);
	execsnoop_bpf__destroy(skel);
	return err < 0;
}
```

`execsnoop.skel.h` is a skeleton that bpftool generates from the `.o`. It embeds the bytecode in the header and generates `open_and_load`, `attach` and `destroy` functions plus fields like `skel->maps.events`, so user space never makes a raw `bpf()` syscall.

### 6.4 Build and run

```bash
ARCH=$(uname -m | sed 's/x86_64/x86/; s/aarch64/arm64/')
clang -g -O2 -target bpf -D__TARGET_ARCH_$ARCH -c execsnoop.bpf.c -o execsnoop.bpf.o
bpftool gen skeleton execsnoop.bpf.o > execsnoop.skel.h
cc -O2 execsnoop.c -lbpf -o execsnoop
sudo ./execsnoop
```

Do not drop `-g`: CO-RE needs the BTF debug info in the `.o`. Run a few commands in another terminal and they show up. Without `sudo` you get `Operation not permitted`; section 8 explains why.

For a fuller template, see [libbpf-bootstrap](https://github.com/libbpf/libbpf-bootstrap). In Go, [cilium/ebpf](https://github.com/cilium/ebpf) does the same skeleton generation with `bpf2go`; in Rust, there is Aya.

## 7. Dealing with the verifier

Most of the time spent writing eBPF goes into satisfying the verifier. Common rejections:

| Error excerpt | Cause | Fix |
|---|---|---|
| `invalid mem access 'map_value_or_null'` (`'ringbuf_mem_or_null'` for a ring buffer) | Result of `bpf_map_lookup_elem` / `bpf_ringbuf_reserve` not checked for NULL | `if (!p) return 0;` first |
| `R1 invalid mem access 'scalar'` or `invalid read from stack` | Dereferencing a kernel pointer directly, or reading an uninitialized stack variable | Use `BPF_CORE_READ` / `bpf_probe_read_kernel`; initialize variables |
| `back-edge` / `infinite loop detected` | The loop count cannot be proven bounded | Loops with a constant bound on 5.3+, `bpf_loop()` on 5.17+; unroll the loop on older kernels |
| `invalid access to map value, value_size=... off=... size=...` | An index might be out of range | Check bounds explicitly before the access, where the verifier can see it |
| `combined stack size ... Too large` | More than 512 bytes of stack | Move big structs into a per-CPU array map |
| `cannot call GPL-restricted function` | LICENSE is not GPL-compatible | Declare `"GPL"` or `"Dual BSD/GPL"` |

The full verifier log is long; the useful part is the last few lines, which show which register it was tracking and what type it thought that register held. libbpf prints the log when a load fails, and `sudo bpftool prog load x.bpf.o /sys/fs/bpf/x` shows it too.

## 8. Environment and permissions

```bash
uname -r                                   # kernel version
ls /sys/kernel/btf/vmlinux                 # BTF is required for CO-RE
grep CONFIG_DEBUG_INFO_BTF /boot/config-$(uname -r)
cat /proc/sys/kernel/unprivileged_bpf_disabled   # non-zero: normal users cannot load any program
```

Key versions:

| Kernel | What it added |
|---|---|
| 4.1 | kprobe programs |
| 4.7 / 4.8 | tracepoints, XDP |
| 5.2 | Instruction limit per program raised from 4,096 to 1 million |
| 5.3 | Bounded loops |
| 5.5 | fentry / fexit |
| 5.7 | BPF LSM |
| 5.8 | Ring buffer, `CAP_BPF` split out |
| 5.17 | `bpf_loop()` |

In practice, **aim for 5.8 or later with BTF in production**. Distribution kernels in Ubuntu 20.10+, Debian 11+ and RHEL 8.2+ ship BTF by default; for older kernels, [BTFHub](https://github.com/aquasecurity/btfhub) provides external BTF files.

To load tracing programs you need `CAP_BPF` + `CAP_PERFMON` (5.8+), or `CAP_SYS_ADMIN` on older kernels. The `Operation not permitted` from running section 6.4 without `sudo` comes from these missing capabilities. `unprivileged_bpf_disabled` controls something else: even when it is 0, normal users can only load a few program types such as socket filters, and most distributions set it to non-zero, which blocks normal users entirely. That is deliberate hardening; do not set it to 0 for convenience. eBPF agents in containers usually run privileged or with those capabilities, and mount `/sys/kernel/btf`, `/sys/fs/bpf` and `/sys/kernel/debug`.

## 9. Inspecting and debugging with bpftool

```bash
sudo bpftool prog list                     # every loaded eBPF program
sudo bpftool prog show id 42 --pretty      # one program: type, load time, maps it uses
sudo sysctl kernel.bpf_stats_enabled=1     # needed for run_cnt / run_time_ns (has overhead, turn it off after)
sudo bpftool map list
sudo bpftool map dump id 7                 # print a map's contents
sudo bpftool prog dump xlated id 42        # bytecode after verification
sudo bpftool prog tracelog                 # output of bpf_printk(), i.e. /sys/kernel/tracing/trace_pipe
```

Run `bpftool prog list` on a machine with Cilium or Falco and you will see dozens or hundreds of programs; plenty of eBPF is probably running around you already. For debugging, add a temporary `bpf_printk("pid=%d", pid);` in the kernel code and read it with `bpftool prog tracelog`: the eBPF version of printf.

## 10. eBPF in production

In networking, Cilium replaces kube-proxy and iptables with eBPF for Kubernetes load balancing and network policy, and Meta's Katran and Cloudflare use XDP for layer-4 load balancing and DDoS mitigation. In observability, Pixie and Grafana Beyla collect HTTP/gRPC request metrics with no code changes, and Parca and Pyroscope do continuous profiling. In security, Falco and Tetragon watch process execution, file access and network connections, and Tetragon can block them in the kernel.

Remember the cost: your program runs once per event. On high-frequency events such as `vfs_read` or `raw_syscalls:sys_enter` that can be hundreds of thousands of times a second. For a quick investigation it does not matter; for an always-on agent, aggregate in the kernel (counts, histograms) and hand user space the result instead of every single event.

## 11. Summary

- eBPF is a safe sandbox in the kernel: the verifier keeps it from crashing, the JIT keeps it fast, maps carry data to user space.
- For troubleshooting, start with the BCC tools and bpftrace one-liners; most problems need no code. The [troubleshooting playbook](https://suzf.net/en/blog/posts/ebpf-troubleshooting-playbook/) maps symptoms to tools.
- For something long-running, use libbpf + CO-RE: build once, run on many kernels with BTF.
- Prefer tracepoints; run 5.8+ kernels with BTF in production; aggregate in the kernel on hot events.

## 12. Related links

**Docs and further reading**

- [ebpf.io](https://ebpf.io/): the eBPF community site, with an introduction and a project index
- [Kernel BPF documentation](https://docs.kernel.org/bpf/), including the [verifier chapter](https://docs.kernel.org/bpf/verifier.html) on what it checks
- [libbpf documentation](https://libbpf.readthedocs.io/)
- Andrii Nakryiko: [BPF CO-RE explained](https://nakryiko.com/posts/bpf-portability-and-co-re/), [BPF CO-RE reference guide](https://nakryiko.com/posts/bpf-core-reference-guide/)
- Brendan Gregg: [*BPF Performance Tools*](https://www.brendangregg.com/bpf-performance-tools-book.html), [Linux performance analysis in 60 seconds](https://www.brendangregg.com/Articles/Netflix_Linux_Perf_Analysis_60s.pdf)

**Tools and libraries**

- [BCC](https://github.com/iovisor/bcc): home of the `*-bpfcc` tools in section 5
- [bpftrace](https://github.com/bpftrace/bpftrace)
- [bpftool](https://github.com/libbpf/bpftool)
- [libbpf-bootstrap](https://github.com/libbpf/libbpf-bootstrap): C project template for libbpf + CO-RE
- [cilium/ebpf](https://github.com/cilium/ebpf) (Go), [Aya](https://github.com/aya-rs/aya) (Rust)
- [BTFHub](https://github.com/aquasecurity/btfhub): external BTF files for older kernels without BTF

**Projects from section 10**

- Networking: [Cilium](https://github.com/cilium/cilium), [Katran](https://github.com/facebookincubator/katran)
- Observability: [Pixie](https://github.com/pixie-io/pixie), [Grafana Beyla](https://github.com/grafana/beyla), [Parca](https://github.com/parca-dev/parca), [Pyroscope](https://github.com/grafana/pyroscope)
- Security: [Falco](https://github.com/falcosecurity/falco), [Tetragon](https://github.com/cilium/tetragon)
