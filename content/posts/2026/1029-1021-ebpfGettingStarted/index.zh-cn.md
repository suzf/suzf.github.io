---
title: "eBPF 入门：不改内核、不重启，看清 Linux 在做什么"
slug: "ebpf getting started"
date: 2026-10-29T10:21:21+08:00
author: "Jeffrey Su"
description: "eBPF 是什么、程序如何经过 verifier 和 JIT 跑进内核、常用挂载点、用 bpftrace 和 BCC 排查问题、用 libbpf + CO-RE 写一个自己的程序，以及内核版本和权限要求。"
categories: ["技能矩阵"]
tags: ["ebpf", "linux", "observability"]
toc: true
draft: false
---

线上机器 CPU 飙高、磁盘延迟抖动、某个进程偷偷连了外网——以前要么加日志重新发版，要么写内核模块冒着宕机的风险。eBPF 让你把一小段经过校验的程序挂到内核的几乎任意事件上，现场采集数据，用完即卸，不改内核、不重启、不动业务代码。本文从原理讲到动手：先用现成工具，再写一个自己的 eBPF 程序。

<!--more-->

## 1. eBPF 是什么

eBPF（extended Berkeley Packet Filter）是 Linux 内核里的一个**沙箱虚拟机**。你用受限的 C（或 bpftrace 这类高级语言）写程序，编译成 eBPF 字节码，交给内核；内核先校验它是安全的，再把它编译成本机指令，挂在你指定的事件上运行：某个系统调用被调用、某个内核函数被执行、网卡收到一个包、用户态程序里的某个函数被调用……

名字来自 1992 年用于 tcpdump 包过滤的 BPF，但今天的 eBPF 早已不只是过滤包。它和内核模块的区别是关键：

| | 内核模块 | eBPF 程序 |
|---|---|---|
| 安全性 | 一个空指针就能让内核崩溃 | 加载前由 verifier 证明不会崩溃、不会死循环 |
| 兼容性 | 与内核版本强绑定，要重新编译 | 借助 BTF + CO-RE，一次编译多个内核版本可跑 |
| 部署 | `insmod`，出错难以回滚 | 默认随加载它的进程退出而卸载（pin 到 `/sys/fs/bpf` 的除外） |
| 能力 | 不受限制 | 只能调用内核提供的 helper 函数 |

一句话：eBPF 牺牲了一部分能力，换来了在生产环境里**敢用**。

## 2. 一个 eBPF 程序是怎么跑起来的

```text
 C / bpftrace 源码
        │  clang -target bpf
        ▼
  eBPF 字节码 (.o)
        │  bpf() 系统调用
        ▼
 ───────────── 内核 ─────────────
  verifier：逐条路径检查安全性
        │
        ▼
  JIT：编译成 x86/arm64 指令
        │
        ▼
  挂载到 hook（kprobe、XDP…），事件触发时运行
        │
        ▼
  maps / ring buffer
 ────────────────────────────────
        │
        ▼
  用户态程序读取结果
```

几个核心概念：

- **verifier（校验器）**：加载时把程序的每条执行路径都走一遍，确认不会越界访问内存、不会读未初始化的变量、一定会结束、只调用允许的 helper。通不过就拒绝加载。这是 eBPF 能放心用在生产上的根本原因。
- **JIT**：校验通过后，字节码被编译成本机指令，运行开销接近原生代码。
- **hook（挂载点）**：程序挂在哪个事件上，决定了它什么时候运行、能拿到什么上下文。
- **map**：内核与用户态、以及多个 eBPF 程序之间共享数据的键值存储，类型有 hash、array、per-CPU array、LRU、ring buffer 等。eBPF 程序本身没有全局状态，计数、直方图、事件队列都放在 map 里。
- **helper 函数**：eBPF 程序与内核交互的唯一途径，比如 `bpf_get_current_pid_tgid()`、`bpf_probe_read_kernel()`、`bpf_ringbuf_submit()`。

## 3. 常用挂载点

| 挂载点 | 触发时机 | 稳定性 | 典型用途 |
|---|---|---|---|
| `tracepoint` | 内核预埋的静态跟踪点 | 稳定，跨版本不变 | 系统调用、调度、块设备 I/O |
| `kprobe` / `kretprobe` | 任意内核函数的入口 / 返回 | 不稳定，函数可能被改名或内联 | 跟踪没有 tracepoint 的内核路径 |
| `fentry` / `fexit` | 内核函数入口 / 返回（5.5+） | 同 kprobe，但开销更低，fexit 能同时拿到参数和返回值 | 替代 kprobe |
| `uprobe` / `uretprobe` | 用户态程序的任意函数 | 随应用版本变化 | 跟踪 OpenSSL、数据库、Go/Java 应用 |
| `USDT` | 应用预埋的静态探针 | 稳定 | MySQL、PostgreSQL、Python、JVM |
| `perf_event` | 定时采样、硬件计数器 | 稳定 | CPU 火焰图 |
| `XDP` | 网卡驱动收到包、分配 skb 之前 | 稳定 | DDoS 防护、负载均衡 |
| `tc` | 流量控制层的进 / 出方向 | 稳定 | 容器网络、策略 |
| `cgroup` / `LSM` | cgroup 内的 socket、设备操作 / 安全钩子（5.7+） | 稳定 | 网络策略、运行时安全 |

选择原则：**有 tracepoint 就用 tracepoint**，没有再用 fentry/kprobe。kprobe 跟踪的是内核内部函数，升级内核后可能找不到符号，写进监控系统之前要想到这一点。

## 4. 从 bpftrace 开始

想快速回答「现在系统里发生了什么」，bpftrace 是最顺手的工具，语法像 awk：`探针 /过滤条件/ { 动作 }`。在 Ubuntu 上 `apt install bpftrace` 即可，需要 root 运行。

```bash
# 谁在执行新进程（跟踪所有 execve）
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_execve { printf("%-6d %-16s %s\n", pid, comm, str(args.filename)); }'

# 谁在打开什么文件
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args.filename)); }'

# 按进程统计系统调用次数，Ctrl-C 后打印
sudo bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'

# vfs_read 的耗时分布（微秒直方图）
sudo bpftrace -e 'kprobe:vfs_read { @start[tid] = nsecs; }
  kretprobe:vfs_read /@start[tid]/ { @us = hist((nsecs - @start[tid]) / 1000); delete(@start[tid]); }'

# 哪些进程在发起 TCP 连接
sudo bpftrace -e 'kprobe:tcp_connect { @[comm] = count(); }'

# 对 PID 1234 以 99Hz 采样用户态调用栈（可做火焰图）
sudo bpftrace -e 'profile:hz:99 /pid == 1234/ { @[ustack] = count(); }'
```

几点说明：

- `@` 开头的是 map，`@[comm] = count()` 就是以进程名为键计数，程序结束时 bpftrace 自动打印。
- `args.filename` 是 tracepoint 的参数，较老的 bpftrace（比如 Ubuntu 22.04 自带的 0.14）要写成 `args->filename`。某个 tracepoint 有哪些参数，用 `sudo bpftrace -lv 'tracepoint:syscalls:sys_enter_openat'` 查看。
- `sudo bpftrace -l 'tracepoint:syscalls:*'` 列出可用探针，支持通配符。
- 采样频率用 99 而不是 100，是为了避开和其他定时任务同频造成的偏差。

## 5. 现成的工具：BCC 和 bpftrace tools

很多常见问题已经有人写好了工具，不用从零写。Ubuntu 上安装 `bpfcc-tools`，命令名带 `-bpfcc` 后缀（其他发行版通常放在 `/usr/share/bcc/tools/` 下，没有后缀）：

| 工具 | 回答的问题 |
|---|---|
| `execsnoop-bpfcc` | 短命进程是谁拉起来的？（CPU 高但 `top` 看不到元凶时首选） |
| `opensnoop-bpfcc` | 进程在打开哪些文件，哪些打开失败了？ |
| `biolatency-bpfcc` | 块设备 I/O 延迟分布 |
| `biosnoop-bpfcc` | 每一次磁盘 I/O 的进程、大小、延迟 |
| `tcplife-bpfcc` | 每条 TCP 连接的起止时间、收发字节数 |
| `tcpretrans-bpfcc` | 哪些连接在重传 |
| `runqlat-bpfcc` | 进程在运行队列里等了多久（CPU 争抢） |
| `profile-bpfcc` | CPU 采样，输出可直接生成火焰图 |
| `oomkill-bpfcc` | OOM killer 杀了谁、当时谁在申请内存 |

bpftrace 包也自带一套同类工具，用 bpftrace 脚本写成，Ubuntu 上装在 `/usr/sbin/` 下、以 `.bt` 结尾，比如 `execsnoop.bt`、`biolatency.bt`、`tcpretrans.bt`。它们本身就是很好的 bpftrace 范例，写自己的脚本前可以先打开看看。

排查性能问题时，Brendan Gregg 的[「60 秒分析」](https://www.brendangregg.com/Articles/Netflix_Linux_Perf_Analysis_60s.pdf)思路很好用：先用 `uptime`、`vmstat`、`iostat` 这些传统工具定位是 CPU、内存、磁盘还是网络，再用对应的 eBPF 工具往下钻。

## 6. 写一个自己的程序：libbpf + CO-RE

bpftrace 适合临时排查；要做成长期运行的 agent，一般用 C 写内核部分、用 libbpf 加载。下面实现一个最小的 execsnoop：每当有进程成功执行 exec，把 PID、父进程 PID 和新的进程名通过 ring buffer 发到用户态。

### 6.1 准备

```bash
sudo apt install clang libbpf-dev linux-tools-common linux-tools-$(uname -r)

# 确认内核开启了 BTF（CO-RE 的前提）
ls /sys/kernel/btf/vmlinux

# 从当前内核导出所有类型定义，替代一堆内核头文件
bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
```

### 6.2 内核部分

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

- `SEC(...)` 告诉 libbpf 这个函数挂在哪里，这里是 `sched:sched_process_exec` 这个 tracepoint。它在 exec 成功之后触发，此时进程名已经换成新程序的名字。如果挂在 `syscalls:sys_enter_execve` 上，exec 还没发生，`bpf_get_current_comm()` 拿到的是调用者（通常是 `bash`）的名字。
- `LICENSE` 必须声明，很多 helper 只对 GPL 兼容的程序开放。
- `bpf_ringbuf_reserve` 可能失败（缓冲区满），**必须检查返回值**，否则 verifier 会拒绝加载。
- `BPF_CORE_READ(task, real_parent, tgid)` 就是 CO-RE：它会记录「读取 `task_struct.real_parent.tgid`」这个意图，加载时 libbpf 根据目标内核的 BTF 修正字段偏移。不同内核里 `task_struct` 的布局不同，同一个 `.o` 照样能跑。
- `bpf_get_current_pid_tgid()` 高 32 位是用户态说的 PID（内核叫 tgid），低 32 位是线程 ID。

### 6.3 用户态部分

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

	skel = execsnoop_bpf__open_and_load();   /* 打开 + 校验 + 加载 */
	if (!skel)
		return 1;
	err = execsnoop_bpf__attach(skel);       /* 挂到 tracepoint 上 */
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

`execsnoop.skel.h` 是 bpftool 根据 `.o` 生成的「骨架」：它把字节码嵌进头文件，并生成 `open_and_load`、`attach`、`destroy` 这些函数和 `skel->maps.events` 这样的字段，用户态不用手写任何 `bpf()` 系统调用。

### 6.4 编译和运行

```bash
ARCH=$(uname -m | sed 's/x86_64/x86/; s/aarch64/arm64/')
clang -g -O2 -target bpf -D__TARGET_ARCH_$ARCH -c execsnoop.bpf.c -o execsnoop.bpf.o
bpftool gen skeleton execsnoop.bpf.o > execsnoop.skel.h
cc -O2 execsnoop.c -lbpf -o execsnoop
sudo ./execsnoop
```

`-g` 不能省，CO-RE 需要 `.o` 里的 BTF 调试信息。另开一个终端随便执行几个命令，就能看到输出。不加 `sudo` 运行会得到 `Operation not permitted`，原因见第 8 节。

更完整的模板可以参考 [libbpf-bootstrap](https://github.com/libbpf/libbpf-bootstrap)。用 Go 的话，[cilium/ebpf](https://github.com/cilium/ebpf) 用 `bpf2go` 实现同样的骨架生成；用 Rust 可以选 Aya。

## 7. 和 verifier 打交道

写 eBPF 程序，大部分时间花在让 verifier 满意上。常见的拒绝原因：

| 报错片段 | 原因 | 解决 |
|---|---|---|
| `invalid mem access 'map_value_or_null'`（ring buffer 是 `'ringbuf_mem_or_null'`） | `bpf_map_lookup_elem` / `bpf_ringbuf_reserve` 的返回值没判空 | 先 `if (!p) return 0;` |
| `R1 invalid mem access 'scalar'` 或 `invalid read from stack` | 直接解引用内核指针，或读了未初始化的栈变量 | 用 `BPF_CORE_READ` / `bpf_probe_read_kernel`；变量先初始化 |
| `back-edge` / `infinite loop detected` | 循环次数无法证明有界 | 5.3+ 用常量上界的循环，5.17+ 用 `bpf_loop()`；更老的内核只能展开循环 |
| `invalid access to map value, value_size=... off=... size=...` | 下标可能越界 | 访问前显式检查边界，让 verifier 看得到 |
| `combined stack size ... Too large` | 栈超过 512 字节 | 大结构放进 per-CPU array map |
| `cannot call GPL-restricted function` | LICENSE 不兼容 GPL | 声明 `"GPL"` 或 `"Dual BSD/GPL"` |

verifier 的完整日志很长，真正有用的是最后几行：报错前它在跟踪哪个寄存器、认为那里是什么类型。libbpf 加载失败时会把日志打出来；用 `sudo bpftool prog load x.bpf.o /sys/fs/bpf/x` 单独加载也能看到。

## 8. 环境和权限要求

```bash
uname -r                                   # 内核版本
ls /sys/kernel/btf/vmlinux                 # 有 BTF 才能用 CO-RE
grep CONFIG_DEBUG_INFO_BTF /boot/config-$(uname -r)
cat /proc/sys/kernel/unprivileged_bpf_disabled   # 非 0：普通用户什么程序都不能加载
```

几个关键版本：

| 内核 | 带来的能力 |
|---|---|
| 4.1 | kprobe 程序 |
| 4.7 / 4.8 | tracepoint、XDP |
| 5.2 | 单个程序指令上限从 4096 条提高到 100 万条 |
| 5.3 | 有界循环 |
| 5.5 | fentry / fexit |
| 5.7 | BPF LSM |
| 5.8 | ring buffer、`CAP_BPF` 权限拆分 |
| 5.17 | `bpf_loop()` |

实际经验：**生产环境最好是 5.8 以上并开启 BTF**。Ubuntu 20.10+、Debian 11+、RHEL 8.2+ 的发行版内核都默认带 BTF；更老的内核可以用 [BTFHub](https://github.com/aquasecurity/btfhub) 提供的外部 BTF 文件。

权限上，加载 tracing 程序需要 `CAP_BPF` + `CAP_PERFMON`（5.8+），老内核需要 `CAP_SYS_ADMIN`。第 6.4 节不加 `sudo` 得到的 `Operation not permitted`，就是因为缺这些 capability。`unprivileged_bpf_disabled` 管的是另一件事：即使它是 0，普通用户也只能加载 socket filter 这类少数程序类型；大多数发行版默认把它设为非 0，彻底禁止普通用户加载。这是有意的安全加固，别为了方便改成 0。容器里跑 eBPF agent 时，通常以 privileged 或加上这几个 capability，并挂载 `/sys/kernel/btf`、`/sys/fs/bpf`、`/sys/kernel/debug`。

## 9. 查看和调试：bpftool

```bash
sudo bpftool prog list                     # 当前加载的所有 eBPF 程序
sudo bpftool prog show id 42 --pretty      # 某个程序的详情：类型、加载时间、用到的 map
sudo sysctl kernel.bpf_stats_enabled=1     # 打开后才显示 run_cnt / run_time_ns（有开销，用完关掉）
sudo bpftool map list
sudo bpftool map dump id 7                 # 打印 map 内容
sudo bpftool prog dump xlated id 42        # 校验后的字节码
sudo bpftool prog tracelog                 # bpf_printk() 的输出，即 /sys/kernel/tracing/trace_pipe
```

在一台跑着 Cilium 或 Falco 的机器上执行 `bpftool prog list`，你会看到几十上百个程序——很多 eBPF 其实已经在你身边运行了。调试时在内核代码里临时加 `bpf_printk("pid=%d", pid);`，再用 `bpftool prog tracelog` 查看，相当于 eBPF 版的 printf。

## 10. eBPF 在生产中的用途

网络方面，Cilium 用 eBPF 替代 kube-proxy 和 iptables 做 Kubernetes 的负载均衡和网络策略，Meta 的 Katran 和 Cloudflare 用 XDP 做四层负载均衡和 DDoS 防护。可观测性方面，Pixie、Grafana Beyla 不改代码就能采集 HTTP/gRPC 请求指标，Parca、Pyroscope 做持续性能剖析。安全方面，Falco、Tetragon 监控进程执行、文件访问和网络连接，Tetragon 还能在内核里直接阻断。

使用时要记住开销：每个事件都会运行一次你的程序。挂在 `vfs_read` 或 `raw_syscalls:sys_enter` 这类高频事件上，每秒可能触发几十万次。临时排查无所谓；做成常驻 agent 时，尽量在内核里聚合（计数、直方图），只把结果交给用户态，而不是把每个事件都发出去。

## 11. 小结

- eBPF 是内核里的安全沙箱：verifier 保证不崩溃，JIT 保证够快，map 负责和用户态交换数据。
- 排查问题先用 BCC 工具和 bpftrace 单行命令，大部分问题不需要写代码。
- 需要长期运行时用 libbpf + CO-RE，一次编译，在开启 BTF 的多个内核上运行。
- 优先用 tracepoint；生产环境选 5.8+ 并开启 BTF 的内核；高频事件上在内核里聚合。

## 12. 相关链接

**文档与延伸阅读**

- [ebpf.io](https://ebpf.io/)：eBPF 社区官网，概念介绍和项目索引
- [内核 BPF 文档](https://docs.kernel.org/bpf/)，其中 [verifier 一章](https://docs.kernel.org/bpf/verifier.html)讲校验规则
- [libbpf 文档](https://libbpf.readthedocs.io/)
- Andrii Nakryiko：[BPF CO-RE 的原理](https://nakryiko.com/posts/bpf-portability-and-co-re/)、[BPF CO-RE 参考指南](https://nakryiko.com/posts/bpf-core-reference-guide/)
- Brendan Gregg：[《BPF Performance Tools》](https://www.brendangregg.com/bpf-performance-tools-book.html)、[60 秒性能分析](https://www.brendangregg.com/Articles/Netflix_Linux_Perf_Analysis_60s.pdf)

**工具与开发库**

- [BCC](https://github.com/iovisor/bcc)：第 5 节的 `*-bpfcc` 工具都来自这里
- [bpftrace](https://github.com/bpftrace/bpftrace)
- [bpftool](https://github.com/libbpf/bpftool)
- [libbpf-bootstrap](https://github.com/libbpf/libbpf-bootstrap)：libbpf + CO-RE 的 C 项目模板
- [cilium/ebpf](https://github.com/cilium/ebpf)（Go）、[Aya](https://github.com/aya-rs/aya)（Rust）
- [BTFHub](https://github.com/aquasecurity/btfhub)：给不带 BTF 的老内核用的外部 BTF 文件

**第 10 节提到的项目**

- 网络：[Cilium](https://github.com/cilium/cilium)、[Katran](https://github.com/facebookincubator/katran)
- 可观测性：[Pixie](https://github.com/pixie-io/pixie)、[Grafana Beyla](https://github.com/grafana/beyla)、[Parca](https://github.com/parca-dev/parca)、[Pyroscope](https://github.com/grafana/pyroscope)
- 安全：[Falco](https://github.com/falcosecurity/falco)、[Tetragon](https://github.com/cilium/tetragon)
