---
title: "用 eBPF 排查变慢的 Linux 服务器：按症状逐个击破"
slug: "ebpf troubleshooting playbook"
date: 2026-10-31T14:00:00+08:00
author: "Jeffrey Su"
description: "什么症状该跑哪个 eBPF 工具：短命进程、CPU 火焰图、运行队列延迟、Off-CPU 时间、磁盘和文件系统延迟、TCP 重传和丢包、DNS、OOM 和静默失败的系统调用，以及关键参数和怎么读输出。"
categories: ["技能矩阵"]
tags: ["ebpf", "linux", "observability", "performance"]
toc: true
draft: false
---

[上一篇 eBPF 文章](https://suzf.net/zh/blog/posts/ebpf-getting-started/)讲了 eBPF 是什么、程序怎样通过验证器，以及怎样用 libbpf 写一个程序。这一篇是实战续篇：服务变慢了或者机器不对劲，你想知道该跑哪个工具、哪些参数要紧、输出在告诉你什么。

全文按症状组织。每一节从经典工具能看到的现象出发，给出回答下一个问题的 eBPF 工具，并说明要看什么。

<!--more-->

所有命令都使用 Ubuntu `bpfcc-tools` 包里的 BCC 工具（这里是 0.29 版），命令名带 `-bpfcc` 后缀；其他发行版通常放在 `/usr/share/bcc/tools/` 下，没有后缀。所有工具都需要 root。逐个事件打印的工具会一直输出，直到按 Ctrl-C；做汇总的工具和 `vmstat` 一样，接受间隔和次数两个参数。

## 1. 先确定是哪种资源

eBPF 工具回答的是很窄、很精确的问题，所以先选问题，再选工具。花一分钟用经典工具看看哪种资源有压力：

```bash
uptime                 # 负载：在上升、下降还是平稳？
vmstat 1               # r（运行队列）、b（阻塞）、si/so（换页）、us/sy/wa/st
mpstat -P ALL 1        # 是不是一个 CPU 打满、其他空闲？
iostat -xz 1           # 每块盘的 r_await/w_await（延迟）、aqu-sz（队列）、%util
sar -n DEV,TCP,ETCP 1  # 吞吐、新建连接、重传
free -m                # 可用内存、swap 使用
dmesg -T | tail        # OOM、磁盘错误、丢包
```

然后跳到对应的小节：

| 看到的现象 | 去看 |
|---|---|
| CPU 很高，但 `top` 里看不出是谁 | [2. 短命进程](#2-cpu-很忙top-却看不出是谁) |
| 某个进程占用大量 CPU | [3. CPU 时间花在哪](#3-某个进程在烧-cpu代码里的哪一段) |
| 负载高，但 CPU 没跑满 | [4. 等 CPU](#4-负载很高cpu-却没跑满) |
| 请求慢，CPU 却很低 | [5. Off-CPU 时间](#5-慢却不占-cpuoff-cpu-时间) |
| `iostat` 延迟高或 `wa` 高 | [6. 磁盘和文件系统](#6-磁盘和文件系统延迟) |
| 超时、建连慢、重传 | [7. 网络](#7-网络建连慢重传和丢包) |
| OOM、换页、缓存未命中 | [8. 内存](#8-内存oom直接回收和页缓存) |
| 有东西失败了，日志却什么都没写 | [9. 错误](#9-静默失败) |

两个习惯会让下面每个工具都更安全、输出更有用：

- **按进程过滤。** 大多数工具接受 `-p PID`。对容器要用宿主机看到的 PID：`docker inspect -f '{{.State.Pid}}' <container>`，在 Kubernetes 节点上则是 `crictl inspect --output go-template --template '{{.info.pid}}' <container-id>`。容器里看到的 PID 是另一个数字。
- **限定运行时长。** 汇总类工具给一个时长；在繁忙的机器上，逐事件追踪的工具跑几秒就停。每个被追踪的事件都要花一点 CPU，而有些事件每秒触发几十万次。

## 2. CPU 很忙，top 却看不出是谁

`top` 每隔几秒采样一次，只显示那一刻存在的进程。一个每秒 fork 上百个短命子进程的程序（每次调用 `curl` 的健康检查、循环跑的定时任务、逐行起 `grep | awk | sed` 的 shell 脚本）可以吃掉整整一个 CPU，却没有任何一个进程出现在列表里。

`execsnoop` 实时打印每一次 `exec()`，带上父进程 PID 和参数：

```bash
execsnoop-bpfcc -T          # 加一列 HH:MM:SS 时间
execsnoop-bpfcc -T -x       # 同时显示失败的 exec()（二进制不存在、没有权限）
execsnoop-bpfcc -P 1234     # 只看 PID 1234 的子进程
```

如果同一条命令每秒刷过很多次，就找到了；`PPID` 告诉你是谁在启动它。与它对应的 `exitsnoop` 在进程退出时打印，带上存活时长和退出码。`exitsnoop-bpfcc -x` 只显示失败的退出，这是抓住被守护进程反复拉起的崩溃循环最快的办法。

## 3. 某个进程在烧 CPU：代码里的哪一段？

当消耗者明确是某个进程时，下一个问题是哪些函数。`profile` 以固定频率在每个 CPU 上采样调用栈，折叠格式的输出可以直接生成火焰图：

```bash
profile-bpfcc -F 99 -f -p 1234 30 > cpu.folded     # 99 Hz、折叠格式、30 秒
git clone https://github.com/brendangregg/FlameGraph
./FlameGraph/flamegraph.pl cpu.folded > cpu.svg
```

在浏览器里打开 SVG。宽度代表 CPU 时间：最宽的"塔"就是要看的地方，每座塔的顶端是真正在运行的函数。`-U` 只看用户态栈，`-K` 只看内核栈；如果大量时间落在 `sys_` 开头的内核帧下面，通常说明程序系统调用太多，而不是计算太多（`syscount-bpfcc -p 1234 -L` 会列出是哪些调用以及总耗时）。

栈的质量取决于符号。原生二进制需要没被 strip 的符号，用户态栈要可靠还需要帧指针。带 JIT 的运行时需要 perf map：Node.js 用 `--perf-basic-prof` 启动，Java 加上 `-XX:+PreserveFramePointer` 并配合 perf-map-agent 这类 agent。没有这些，你只会看到一堆 `[unknown]`。

## 4. 负载很高，CPU 却没跑满

负载（load average）统计的是正在运行*或等待运行*的任务（在 Linux 上还包括不可中断睡眠的任务）。如果负载很高但 `mpstat` 显示有空闲，或者一台看起来只忙了一半的机器延迟很差，就去测任务等 CPU 等了多久，也就是**运行队列延迟**：

```bash
runqlat-bpfcc -m 10 1       # 一张 10 秒的直方图，单位毫秒
runqlat-bpfcc -P 10 1       # 每个进程一张直方图
runqslower-bpfcc -P 5000    # 打印每次超过 5 ms 的等待，以及当时是谁占着 CPU
```

`runqlat` 打印任务从可运行到真正拿到 CPU 之间的时间分布。健康的机器上几乎全部落在微秒级的桶里。尾部拖到毫秒级，说明任务在排队：可运行线程太多、工作被绑在部分 CPU 上而其他 CPU 闲着，或者有吵闹的邻居。`runqslower -P` 会给出等待的任务和这期间占着 CPU 的任务。

在容器里还要检查 CPU 限额。容器用完 CFS 配额后，会在本周期剩下的时间里被暂停，表现为宿主机 CPU 很闲、请求却很慢。在 cgroup v2 上，容器 `cpu.stat` 里的 `nr_throttled` 和 `throttled_usec` 显示被限流的次数和时长。

## 5. 慢却不占 CPU：Off-CPU 时间

如果一个请求耗时 800 ms，而进程只在 CPU 上待了 20 ms，剩下的时间都在等待：等锁、等磁盘、等网络、主动 sleep，或者等另一个线程。CPU 采样完全看不到这些。`offcputime` 在线程每次离开 CPU 时记录调用栈，并累计它离开了多久：

```bash
offcputime-bpfcc -f -p 1234 30 > offcpu.folded
./FlameGraph/flamegraph.pl --color=io --title="Off-CPU time" --countname=us offcpu.folded > offcpu.svg
```

这时宽度代表*阻塞*的时间。从下往上读：用户态帧说明是哪段代码在等，顶部的内核帧说明在等什么。`futex_wait` 是锁或条件变量，`io_schedule` 或 `blk_` 开头的帧是磁盘 I/O，`tcp_recvmsg` 或 `sk_wait_data` 是在等网络，`do_nanosleep` 是主动 sleep。等活干的空闲工作线程也会显示成很宽的塔，这是正常的，要看的是处理慢请求的那些线程。

两个参数能减少噪音：`-m 1000` 只保留超过 1 ms 的等待，`--state 2` 只保留不可中断睡眠（`TASK_UNINTERRUPTIBLE`，通常是磁盘）。调度事件非常频繁，所以 `offcputime` 比这里大多数工具开销都大；在繁忙的生产机器上要让它短跑。

## 6. 磁盘和文件系统延迟

`iostat` 给的是每块盘的平均值。平均 5 ms 可能是每次 I/O 都 5 ms，也可能是大多数 0.1 ms、少数 200 ms，这两种情况的修法完全不同。`biolatency` 给出分布：

```bash
biolatency-bpfcc -D -m 10 1     # 每块盘一张 10 秒的直方图，单位毫秒
biolatency-bpfcc -Q -D 10 1     # 把在系统队列里排队的时间也算进去，而不只是设备上的时间
```

出现两个峰通常意味着两类 I/O，比如小的缓存读和大的写，或者一个大多数时候很快、偶尔卡顿的设备。把数字和设备应有的表现比一比：本地 NVMe 大多在 1 毫秒以内，而 EBS 这类网络块存储在个位数毫秒。如果加上 `-Q` 后多出很多，说明 I/O 在系统队列里排队，同时发出的请求超过了设备能处理的量。

要看是谁在做 I/O，`biosnoop` 会逐条打印请求的进程、读写方向、大小和延迟（`-Q` 时有 `QUE(ms)`，设备上的延迟是 `LAT(ms)`）。它的 man page 里有一个提醒：进程名是发出 I/O 时正在运行的那个进程，所以由内核稍后刷盘的写操作，常常显示为内核工作线程，而不是写数据的那个程序。

应用真正感受到的是文件系统延迟，其中包括锁、页缓存未命中和磁盘。`*slower` 系列工具在文件系统层追踪操作，并把慢的操作连同文件名打印出来：

```bash
ext4slower-bpfcc 10          # ext4 上超过 10 ms 的读、写、open 和 fsync
xfsslower-bpfcc 10           # XFS 上的同样功能
cachestat-bpfcc 1            # 每秒的页缓存命中、未命中和命中率
```

慢的 `S`（fsync）行是一个经典发现：数据库或日志组件每次写都在 sync。`cachestat` 里命中率下降、同时读越来越慢，说明工作集已经放不进内存了。

## 7. 网络：建连慢、重传和丢包

网络问题大多表现为别人日志里的超时。先看哪些连接建立得慢：

```bash
tcpconnlat-bpfcc 100      # 超过 100 ms 的出站建连，带 PID 和远端地址
tcplife-bpfcc -L 443      # 本地端口 443 上的每个连接：时长和收发 KB
gethostlatency-bpfcc      # DNS 解析及其耗时
```

建连恰好花了 1 秒多或 3 秒多，就是 SYN 被重传了：第一个 SYN 或它的回包丢了，常见原因是监听队列溢出或防火墙丢弃。`tcplife` 是观察连接频繁新建关闭的廉价方法（成千上万个不到 1 毫秒的连接说明少了连接池），也能看出哪些对端传输的数据最多。`gethostlatency` 只能看到经过 C 库 `getaddrinfo()` 的解析；使用纯 Go 解析器的 Go 程序会绕过它，这类程序要在 DNS 服务器上或用 `tcpdump port 53` 查。

对已建立的连接，看重传和丢包：

```bash
tcpretrans-bpfcc          # 每次重传：地址、端口、TCP 状态
tcpretrans-bpfcc -c       # 改为按连接统计重传次数，按 Ctrl-C 时打印
tcpdrop-bpfcc             # 内核丢弃的包，每个都带上丢弃它的内核调用栈
tcpsynbl-bpfcc            # 每个 SYN 到达时的 SYN 积压长度，每种积压上限一张直方图
```

`tcpretrans` 会点出正在丢包的连接。如果全都发往同一个对端或同一个网段，问题在那条路径上；如果分散在各处，就看本机网卡、主机带宽上限或实例规格。它的 `PID` 列通常是 0，因为大多数重传由内核定时器触发，而不是由进程发起。

`tcpdrop` 为每个被丢弃的包打印内核调用栈，栈里的函数名告诉你是哪道检查把它丢掉的：accept 队列满了、socket 缓冲区上限、校验和错误、netfilter 规则。在较新的内核上它使用 `skb:kfree_skb` tracepoint，该 tracepoint 会记录丢包原因。如果 `tcpsynbl` 显示积压已到上限，说明应用调用 `accept()` 不够快，或者 `listen()` 的 backlog 设得太小，可以用 `nstat -az TcpExtListenOverflows` 确认。

## 8. 内存：OOM、直接回收和页缓存

```bash
oomkill-bpfcc             # 每次 OOM：被杀的进程、触发它的任务、当时的负载
drsnoop-bpfcc -p 1234     # 直接回收事件，以及每次让进程卡了多久
memleak-bpfcc -p 1234 30  # 按调用栈列出尚未释放的分配，每 30 秒一次
```

`dmesg` 也会记录 OOM，但 `oomkill` 能告诉你发生时是哪个任务在分配内存，而它往往不是被杀的那个。`drsnoop` 解释了一类特定的延迟尖刺：空闲内存不足时，申请内存的进程必须先亲自回收页面才能继续，这个工具会打印每次停顿持续了多久、回收了多少页。`memleak` 跟踪每一次 `malloc()` 和 `free()`，找出从未释放的分配。进程内存持续增长时它很有用，但开销很大，只在短时间内挂上，或者在测试实例上用。

## 9. 静默失败

程序经常在出错时重试或降级，却不写任何日志。失败的系统调用会暴露它们碰到了什么：

```bash
opensnoop-bpfcc -x -p 1234      # 只看失败的 open：缺失的配置文件、错误的路径、EACCES
syscount-bpfcc -x -P            # 按进程统计失败的系统调用
syscount-bpfcc -e ENOSPC        # 只看以 ENOSPC 失败的调用
execsnoop-bpfcc -x              # 失败的 exec()
```

要弄清一个程序*实际上*在找哪个配置文件、按什么顺序找，`opensnoop -x` 是最快的办法。一个进程每秒有几千次调用以 `EAGAIN` 失败，通常是在一个非阻塞 socket 上空转。

## 10. 没有现成工具时

BCC 工具集里还有几个通用工具，可以追踪你指定的任意函数：

```bash
funclatency-bpfcc -m -p 1234 c:fsync                          # libc fsync() 耗时的直方图
funclatency-bpfcc -u vfs_read                                 # 内核 vfs_read() 的延迟，单位微秒
trace-bpfcc 'r::do_sys_openat2 (retval < 0) "open failed: %d", retval'   # 打印失败的 open
argdist-bpfcc -p 1234 -C 'p:c:write(int fd):int:fd'           # 按文件描述符统计 write() 次数
```

前缀表示函数在哪里：没有前缀或 `p::` 是内核函数，`r::` 是内核函数的返回，`c:` 是 C 库，也可以写任意二进制或库的路径。内核函数名会随版本变化（6.x 内核上 open 走的是 `do_sys_openat2`，老教程里写的是 `do_sys_open`），所以先用 `bpftrace -l 'kprobe:do_sys_open*'` 确认。`syscalls:sys_enter_openat` 这样的 tracepoint 是更稳定的选择。

需要自定义聚合时，就写一行 bpftrace。例如统计每个进程 `read()` 返回字节数的分布：

```bash
bpftrace -e 'tracepoint:syscalls:sys_exit_read /args.ret > 0/ { @bytes[comm] = hist(args.ret); }'
```

## 11. 开销与安全

这些工具本来就是为在生产机器上运行而设计的，验证器保证它们不会让内核崩溃。但每个事件仍然有成本，要管住的就是这个：

- **便宜**：挂在低频事件上的工具，比如 `execsnoop`、`tcpconnlat`、`tcpretrans`、`oomkill`，以及带阈值的 `ext4slower`。
- **中等**：在内核里聚合高频事件的汇总类工具，比如 `biolatency`、`runqlat` 和 99 Hz 的 `profile`。
- **昂贵**：挂在每次调度切换、每次内存分配或每次系统调用上并把事件送到用户态的工具：`offcputime`、`memleak`、对非常繁忙的进程跑 `syscount`、不加过滤的 `opensnoop`。

先用便宜的，按 PID 过滤，其他的给定时长。工具退出时会卸载自己的程序；`bpftool prog list` 能看到还挂着的东西。

## 12. 速查表

| 症状 | 第一个工具 | 接下来 |
|---|---|---|
| CPU 忙，`top` 里找不到元凶 | `execsnoop -T` | `exitsnoop -x` |
| 某个进程占 CPU | `profile -F 99 -f -p PID` → 火焰图 | `syscount -p PID -L` |
| CPU 闲着但延迟高 | `runqlat -m 10 1` | `runqslower -P`、cgroup `cpu.stat` |
| 慢，CPU 低 | `offcputime -f -p PID` → 火焰图 | 对应的后续小节 |
| 磁盘慢 | `biolatency -D -m 10 1` | `biosnoop`、`ext4slower 10` |
| 读越来越慢 | `cachestat 1` | `free -m`、内存限制 |
| 建连慢或失败 | `tcpconnlat 100` | `tcpsynbl`、`nstat` |
| 已建立的连接超时 | `tcpretrans -c` | `tcpdrop` |
| DNS 慢 | `gethostlatency` | 解析器配置 |
| 进程被杀 | `oomkill` | `drsnoop`、`memleak` |
| 静默失败 | `opensnoop -x`、`syscount -x -P` | `trace` |

想了解这些工具背后的原理，以及没有合适工具时怎样自己写，请看 [eBPF 入门](https://suzf.net/zh/blog/posts/ebpf-getting-started/)。Brendan Gregg 的《BPF Performance Tools》对每个工具都有深入讲解，每个 BCC 工具也都附带 man page 和一份带注解输出的 `_example.txt`。
