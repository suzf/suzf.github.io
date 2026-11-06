---
title: "用 uprobe 和 USDT 追踪用户态程序：不改代码看清函数调用"
slug: "ebpf uprobe usdt"
date: 2026-11-05T15:49:50+08:00
author: "Jeffrey Su"
description: "uprobe、uretprobe 和 USDT 的工作原理，用 bpftrace 读用户态函数的参数、返回值和延迟，追踪 libc 和 OpenSSL 看到 TLS 明文，用 Python 的 USDT 探针看审计事件和 GC 停顿，以及 Go 程序、二进制替换和开销方面的坑。"
categories: ["技能矩阵"]
tags: ["ebpf", "linux", "observability", "bpftrace"]
toc: true
draft: false
---

[第一篇](https://suzf.net/zh/blog/posts/ebpf-getting-started/)讲了 eBPF 的原理，[第二篇](https://suzf.net/zh/blog/posts/ebpf-troubleshooting-playbook/)用现成工具排查问题，看的大多是内核：调度、磁盘、TCP。可很多问题出在应用自己身上：某个函数为什么慢、收到了什么参数、加密之前发出去的到底是什么。这一篇把探针挂进用户态程序，不改代码、不重启进程，直接看函数调用。

<!--more-->

文中的命令都在 Ubuntu 24.04（内核 6.8、bpftrace 0.20.2）上跑过，输出来自一台用 QEMU 模拟的测试虚拟机，所以和时间有关的数字偏大。所有 bpftrace 命令都需要 root。

## 1. uprobe 是怎么工作的

**uprobe** 让你在用户态程序的任意一条指令上挂 eBPF 程序，最常用的是挂在函数入口。挂载时，内核把这个地址上的指令换成一个断点（x86 上是 `int3`）。程序执行到这里就陷入内核，内核运行你的 eBPF 程序，然后在一块专门的内存页里执行被替换掉的那条原始指令（有些指令直接由内核模拟），再回到程序继续跑。

有三点值得记住：

- **探针挂在文件上，不是挂在进程上。** 内核按「哪个文件、哪个偏移」记录 uprobe，所以所有映射了这个二进制或这个库的进程都会命中，包括挂载之后才启动的进程。要只看一个进程，得用 `-p` 把 PID 告诉内核，第 4 节会讲为什么不能只在脚本里过滤。
- **每次命中都要进出一次内核。** 一次普通函数调用是纳秒级的，命中一次 uprobe 大约要微秒级。挂在每秒调用几次的函数上无所谓，挂在每秒几百万次的 `malloc()` 上，应用会明显变慢。
- **uretprobe 靠改返回地址。** 要在函数返回时触发，内核在函数入口把栈上的返回地址换成一个跳板地址，函数返回时先跳到跳板、陷入内核，再回到真正的返回地址。会自己检查或搬动栈的运行时（比如 Go）受不了这种改动，第 7 节会看到后果。

**USDT**（User Statically-Defined Tracing）是另一条路：开发者在代码里预埋探针，编译后它只是一条 `nop` 指令，外加 ELF 文件 `.note.stapsdt` 段里的一条说明，记录探针的位置和参数在哪里。没人追踪时它几乎没有开销；挂上之后，内核在那条 `nop` 上放一个 uprobe。好处是探针名和参数由开发者维护，不像函数名那样随版本变化。

## 2. 准备一个示例程序

下面这个小程序模拟一个处理订单的服务：每处理完一个订单休息 50 ms，每个订单「干活」0 到 19 ms，数量大于 8 的订单被拒绝。它还用 `DTRACE_PROBE3` 预埋了一个 USDT 探针：

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

`sys/sdt.h` 来自 `systemtap-sdt-dev` 包，它只是一个头文件，不会引入运行时依赖。编译时带上 `-g`，后面就能用参数名而不是寄存器序号；然后在后台跑两份：

```bash
sudo apt install systemtap-sdt-dev
gcc -O2 -g -o orders orders.c
./orders > /dev/null &
./orders > /dev/null &
```

## 3. 找到能挂的函数

`bpftrace -l` 列出一个二进制里所有能挂 uprobe 的符号：

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

如果编译时带了 `-g`，`-lv` 还能从调试信息里读出参数：

```bash
sudo bpftrace -lv 'uprobe:./orders:handle_order'
```

```text
uprobe:./orders:handle_order
    int id
    const char* sku
    int qty
```

列表里有没有你要的函数，取决于编译和打包方式。我用同一份代码试了两种常见情况：

- **strip 过的二进制**：`strip` 删掉了符号表，`bpftrace -l` 什么都列不出来。发行版的包大多是 strip 过的，只剩动态导出的符号，也就是库的公开 API。调试符号通常在单独的 `-dbgsym` 包里。
- **被内联的函数**：把 `handle_order` 改成 `static`，再用 `-O2` 编译成 `orders_static`，它只被调用一次，编译器就把它内联进了 `main`，符号表里不再有这个函数。这时 `bpftrace -e 'uprobe:./orders_static:handle_order {}'` 会报 `No probes to attach`。符号还在、但某些调用点被内联的情况更隐蔽：探针挂上了，却漏掉一部分调用。

不想用 root 时，`nm orders | grep handle_order` 看符号表，`readelf -n orders` 看 USDT 探针。

## 4. 读参数、返回值和延迟

uprobe 里 `arg0`、`arg1`……是函数的前几个参数（x86-64 上按调用约定从 `rdi`、`rsi`、`rdx` 等寄存器里取），指针要用 `str()` 读成字符串：

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

两个进程都出现了，这就是「探针挂在文件上」。两个进程的订单号和内容一模一样，是因为它们在同一秒启动，`srand(time(NULL))` 的种子相同，并不是同一次调用打印了两遍。有调试信息时，也可以写成 `args.id`、`str(args.sku)`、`args.qty`，不用记参数顺序。

`str()` 读出来是空字符串时，先别怀疑参数位置。eBPF 程序读用户态内存时不能触发缺页：如果那一页还没映射进这个进程的页表（哪怕文件内容早就在页缓存里），读取就会失败，`str()` 返回空。我第一版示例程序没有那行 `printf`，`handle_order` 自己从不读 `sku`，那几个字符串所在的页从没被访问过，结果每一行都是 `sku=`；加上 `printf` 之后就正常了。真实程序里，参数通常刚被调用方用过，很少碰到这个问题。

### 延迟和返回值

入口记下时间，返回时算差值，就是这个函数的延迟分布。uretprobe 里的 `retval` 是返回值：

```bash
sudo bpftrace -e '
uprobe:./orders:handle_order { @start[tid] = nsecs; }
uretprobe:./orders:handle_order /@start[tid]/ {
    @ms = hist((nsecs - @start[tid]) / 1000000);
    @ret[(int32)retval] = count();
    delete(@start[tid]);
}'
```

按 Ctrl-C 后打印：

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

看这张图要注意，`hist()` 按 2 的幂分档，越往后档越宽：`[8, 16)` 一档就装下了 0 到 19 里的 8 个取值，`[16, 32)` 也装下了 16 到 19 这 4 个，所以即使在真机上，也会有六成调用落在 8 到 32 ms。模拟虚拟机的影响体现在别处：`usleep()` 普遍会多睡一些，`[16, 32)` 理论上应该占 20%，这里占了 35%，还有 10 次超过了 32 ms。被拒绝的订单约占 22%，接近「数量为 9 或 10 就拒绝」的 2/10。

几个细节：

- **`(int32)retval` 的转换不能省。** `retval` 是 64 位无符号数，而函数返回的是 32 位的 `int`，不转换的话 `-1` 会显示成 `4294967295`。
- **用 `tid` 做键。** 同一个函数可能在多个线程里同时执行，按线程区分才能把入口和返回配对。
- **`/@start[tid]/` 过滤条件不能省。** 两个探针不是在同一瞬间挂上的，如果 uretprobe 先生效，某次调用就只有返回、没有入口时间，`@start[tid]` 读出来是 0，会算出一个巨大的延迟。挂载之前就已经进入函数的调用倒不用担心：返回地址是在入口处改的，它们根本不会触发 uretprobe。
- 退出时 bpftrace 会把没清理的 map 都打印出来，所以输出最后多了一行 `@start[118]`，那是 Ctrl-C 时还在函数里的调用。

### 只看一个进程

`-p PID` 只追踪一个进程。这次运行里两个 `orders` 进程的 PID 是 119 和 120：

```bash
sudo bpftrace -p 119 -e 'uprobe:./orders:handle_order { @[pid] = count(); }'
```

```text
Attaching 1 probe...
@[119]: 140
```

另一个 `orders` 进程不再出现。对生产机器，这是减少开销最简单的办法：`-p` 把 PID 交给内核，内核只在这个进程里放断点，其他进程根本不会陷入内核。在脚本里写 `/pid == 119/` 就不一样了，每个进程照样会撞上断点，只是 eBPF 程序什么都不记，开销一点没少。

我在虚拟机里验证过这一点。另一次运行里两个进程是 117 和 118，我在追踪时读了它们 `handle_order` 的第一个字节：平时是 `0xf3`（`endbr64` 指令的开头），放了断点就变成 `0xcc`（`int3`）。用 `-p 117` 时只有 117 变成 `0xcc`；用 `/pid == 117/` 过滤时，两个进程都是 `0xcc`。

## 5. 追踪共享库：libc 和 OpenSSL

库函数也是 uprobe 的目标。bpftrace 能按短名字找到库，`libc` 会被解析成 `/lib/x86_64-linux-gnu/libc.so.6`。比如看一个 Python 进程（PID 126，就是第 6 节用到的那个测试脚本）的 `malloc()` 请求大小分布：

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

总共只有几十次调用。Python 自己的分配器 pymalloc 包办了 512 字节以下的小对象，交给 `malloc()` 的主要是更大的块，以及解释器里少数直接调用 `malloc()` 的地方。

这里 `-p` 尤其重要：`libc.so.6` 被机器上几乎所有进程映射，不加 `-p`，每个进程的每次 `malloc()` 都会陷入内核。

容器里的进程用的是容器镜像里的库，不是宿主机上的那个文件。要么用 `-p` 指定进程，要么从宿主机通过 `/proc/PID/root` 写出容器里的路径，比如 `uprobe:/proc/1234/root/usr/lib/x86_64-linux-gnu/libc.so.6:malloc`。

### 在加密之前看到 TLS 明文

HTTPS 流量在网卡上是加密的，tcpdump 抓到的只是密文。但程序把数据交给 OpenSSL 的 `SSL_write()` 时，数据还是明文；`SSL_read()` 返回时，数据已经解密好了。在这两个函数上挂 uprobe，就能看到加密前和解密后的内容。

我在虚拟机里用 Python 起了一个 HTTPS 服务，再用 curl 带着一个 `Authorization` 头去请求它：

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

请求头里的 token 原样可见，服务端的响应也一样。注意两点：

- curl 调用的是 `SSL_write`，Python 调用的是 `SSL_write_ex`，只挂一个就会漏掉另一半。读的方向同理，有 `SSL_read` 和 `SSL_read_ex`。
- bpftrace 默认只读 64 字节字符串，0.20 版用 `BPFTRACE_MAX_STRLEN` 调大（这里设成 200）。旧变量名 `BPFTRACE_STRLEN` 还能用，但会打印一行弃用警告。

读的方向要多一步：调用 `SSL_read()` 时缓冲区还是空的，得在入口记下缓冲区地址，等返回时按返回的字节数去读：

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

这一招只对**动态链接系统 OpenSSL** 的程序有效。Go 的 `crypto/tls`、静态链接 BoringSSL 的程序（Envoy、Chrome）、用 rustls 的 Rust 程序、Java 自己的 TLS 实现都不走 `libssl.so`，需要针对各自的函数另写探针。BCC 里的 `sslsniff` 是这个思路的完整版本，支持 OpenSSL、GnuTLS 和 NSS。

反过来看，这也说明在一台机器上能加载 eBPF 程序，就能看到所有进程的明文流量和密钥材料。`CAP_BPF`、`CAP_PERFMON`、`CAP_SYS_ADMIN` 都应该当作 root 来管理。

## 6. USDT：程序自己预埋的探针

示例程序里的 `DTRACE_PROBE3(orders, shipped, id, sku, qty)` 就是一个 USDT 探针，提供者是 `orders`，名字是 `shipped`：

```bash
sudo bpftrace -l 'usdt:./orders:*'
```

```text
usdt:./orders:orders:shipped
```

按商品统计发货数量：

```bash
sudo bpftrace -e 'usdt:./orders:orders:shipped { @qty[str(arg1)] = sum(arg2); }'
```

```text
Attaching 1 probe...
@qty[apple]: 262
@qty[cherry]: 400
@qty[banana]: 494
```

和 uprobe 比，USDT 的位置和参数是开发者定的：函数被重命名、拆分或者内联，探针都还在。被拒绝的订单不会走到 `shipped`，所以这里统计的是真正发货的数量，这种「业务语义」是挂在函数入口上的 uprobe 拿不到的。

### Python 的 USDT 探针

不少运行时和数据库自带 USDT 探针，前提是编译时打开了支持（通常是 `--enable-dtrace` 或 `--with-dtrace`）。Ubuntu 24.04 的 Python 3.12 带了这几个：

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

Python 文档里还提到 `function__entry`、`function__return` 和 `line` 三个探针，这个版本里没有，所以想按 Python 函数追踪，得另找办法。

`audit` 探针对应 Python 的审计钩子（PEP 578）：打开文件、建立连接、启动子进程这些敏感操作都会触发一个审计事件，`arg0` 是事件名。我的测试脚本每秒打开一个文件、连一次本地端口、跑一次子进程：

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

不用改一行 Python 代码，就知道一个进程打开了什么、连了哪里、启动了什么。这几个探针带信号量（semaphore）：只有追踪器在附加时把计数加一，Python 才会去准备参数，没人追踪时开销接近零。bpftrace 会替你处理信号量；在我的测试里，不加 `-p` 也能看到机器上所有已经在运行的 Python 进程的事件。

`gc__start` 和 `gc__done` 能量出每次垃圾回收停顿了多久：

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

大多数是年轻代的小回收，在 128 µs 以内。我的脚本每秒显式调用一次 `gc.collect()`，尾巴上那几次几十毫秒的停顿大多是这些完整回收；脚本每轮还会新建 20 万个对象，也可能触发自动的老年代回收（模拟环境里的时间都偏大）。Python 服务的延迟毛刺，往往就藏在这类停顿里。

其他常见的 USDT 来源：

- **PostgreSQL**：用 `--enable-dtrace` 编译时，有查询、锁、事务等探针。
- **MySQL**：8.0 之前的版本。
- **HotSpot JVM**：GC、类加载、线程这类探针默认就有；方法调用、对象分配和锁的探针要分别用 `-XX:+DTraceMethodProbes`、`-XX:+DTraceAllocProbes`、`-XX:+DTraceMonitorProbes` 打开。以前的总开关 `-XX:+ExtendedDTraceProbes` 在 JDK 19 弃用，JDK 20 起不再生效。
- **glibc**：除了 `setjmp`、`longjmp` 和一组内存分配器探针，还有 `pthread_create`、`mutex_entry`、`mutex_acquired`、`cond_wait` 等线程和锁的探针，查锁竞争很有用。

`readelf -n 二进制 | grep -A3 stapsdt` 能看出一个文件里有没有。

## 7. Go 程序：入口能看，返回别碰

下面这个 Go 程序每次起一个新的 goroutine 调用 `handle()`，处理完休息 50 ms 再起下一个；`deep()` 的递归让新 goroutine 的栈不断增长：

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
	return qty*2 + deep(200)%2 // deep() 让 goroutine 的栈增长
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

用 `go build -o gosvc gosvc.go` 编译后运行。`go build` 默认保留符号表（除非加了 `-ldflags="-s -w"`），函数名带包名：

```bash
sudo bpftrace -l 'uprobe:./gosvc:main.*'
```

```text
uprobe:./gosvc:main.deep
uprobe:./gosvc:main.handle
uprobe:./gosvc:main.main
uprobe:./gosvc:main.main.func1
```

读参数时要注意，Go 1.17 起在 amd64 上用自己的寄存器调用约定，整数参数依次放在 `rax`、`rbx`、`rcx`、`rdi`、`rsi`、`r8`……，和 C 不一样，所以 `arg0` 读到的不是第一个参数。用 `reg()` 直接读寄存器：

```bash
sudo bpftrace -e 'uprobe:./gosvc:main.handle { printf("id=%d qty=%d\n", reg("ax"), reg("bx")); }'
```

```text
Attaching 1 probe...
id=3259 qty=9
id=3260 qty=0
id=3261 qty=1
```

**千万不要在 Go 函数上用 uretprobe。** Go 的 goroutine 栈一开始很小，不够时运行时会把整个栈复制到一块更大的内存；复制栈和 GC 扫描栈时，它都要沿着返回地址逐帧回溯。uretprobe 改过的返回地址指向内核映射进进程的一页跳板（`/proc/PID/maps` 里显示为 `[uprobes]`），不属于任何 Go 函数，运行时找不到对应的帧，进程直接崩溃。我在 `main.handle` 上挂了一个 uretprobe，追踪开始后不久服务就挂了：

```text
runtime: g 1317: unexpected return pc for main.handle called from 0xffffffffffe000
stack: frame={sp:0xc00006bf98, fp:0xc00006bfb0} stack=[0xc00006b000,0xc00006c000)
```

`0xffffffffffe000` 就是那页跳板的地址，在地址空间的最顶端：挂着 uretprobe 时，`/proc/PID/maps` 里 `[uprobes]` 那一行正是 `ffffffffffe000-fffffffffff000`。这台虚拟机的 CPU 开了 5 级页表，所以地址这么高；普通机器上大约是 `0x7fffffffe000`。

通常的绕法是不用 uretprobe，而是在函数里每条 `ret` 指令上挂普通 uprobe（用 `objdump -d` 找偏移），返回值就在 `rax` 里。但 Ubuntu 24.04 的 bpftrace 0.20.2 编译时没有带偏移检查支持，`uprobe:./gosvc:main.handle+0x3d` 和直接写地址都会被拒绝，加 `--unsafe` 也不行：

```text
ERROR: Can't check if uprobe is in proper place (compiled without (k|u)probe offset support): ./gosvc:main.handle+61
```

要在这个环境里看 Go 函数的返回值，得用自己编译的 bpftrace，或者写 libbpf 程序自己算偏移。另外，goroutine 可能在函数执行中途被调度到另一个线程上，所以 Go 里按 `tid` 配对入口和返回并不可靠。

Java、Node.js 这类带 JIT 的运行时更麻烦：热点代码是运行时生成的，没有固定的文件和偏移，uprobe 挂不上去。它们要靠运行时自带的 USDT 探针，或者用 perf map 做采样。

## 8. 上生产前要知道的事

- **先估算调用频率。** 开销和命中次数成正比。先用 `count()` 看看每秒多少次；计数本身每次命中也要进出内核，所以估算时也加上 `-p`，只跑一秒。`interval:s:1 { exit(); }` 会在 1 秒后自动退出并打印计数：

  ```bash
  sudo bpftrace -p 119 -e 'uprobe:./orders:handle_order { @calls = count(); } interval:s:1 { exit(); }'
  ```

  几万次以上就要考虑缩短追踪时间，或者换一个调用更少的函数。
- **换了二进制，探针不会跟过去。** uprobe 绑定的是挂载时那个文件。我在追踪期间用 `cp` 加 `mv` 替换了 `orders` 并启动一个新进程，结果统计里只有两个旧进程，新进程一次都没出现。部署新版本后要重新挂载。
- **函数名不是接口。** 下个版本函数可能被改名、内联或者删掉。改名和删掉还好，bpftrace 会直接报错；麻烦的是函数还在，但部分调用被内联了，或者调用路径和含义变了，脚本照样跑，结果却悄悄地不对了。能用 USDT 就用 USDT；用 uprobe 时，每次升级后先确认数字还合理。
- **读字符串可能是空的。** 原因见第 4 节：被追踪的进程还没碰过那块内存时，eBPF 读不到。
- **注意数据安全。** 能挂 uprobe 就能读进程的任何内存，包括 TLS 明文、密码和密钥。追踪的输出也要当作敏感数据处理。

## 9. 小结

- uprobe 把断点放进文件，所有用这个文件的进程都会命中；用 `-p` 缩小范围，用 `count()` 先估算频率。
- 参数从 `arg0` 开始读，有调试信息时用 `args.名字`；返回值用 uretprobe 的 `retval`，有符号的返回值要先转换。
- 库函数同样能追踪：`malloc()` 的分配大小、OpenSSL 加密前的明文。
- USDT 是程序自己定义的稳定探针，Python 的 `audit` 和 GC 探针不用改代码就能用。
- Go 用寄存器传参，而且绝不能挂 uretprobe；JIT 代码用不了 uprobe。

## 10. 相关链接

**文档**

- [bpftrace 手册：探针类型](https://github.com/bpftrace/bpftrace/blob/master/man/adoc/bpftrace.adoc)：uprobe、uretprobe、usdt 的语法和限制
- [内核文档：基于 uprobe 的事件追踪](https://docs.kernel.org/trace/uprobetracer.html)
- [SystemTap wiki：用户态探针的实现](https://sourceware.org/systemtap/wiki/UserSpaceProbeImplementation)：`sys/sdt.h` 和 `.note.stapsdt` 的格式
- [Python 文档：用 DTrace 和 SystemTap 检测 CPython](https://docs.python.org/zh-cn/3/howto/instrumentation.html)、[审计事件列表](https://docs.python.org/zh-cn/3/library/audit_events.html)
- [Go 内部 ABI 规范](https://github.com/golang/go/blob/master/src/cmd/compile/abi-internal.md)：寄存器传参的顺序

**工具**

- [BCC 的 sslsniff](https://github.com/iovisor/bcc/blob/master/tools/sslsniff.py)：追踪 OpenSSL、GnuTLS 和 NSS 的明文
- bpftrace 自带的 `/usr/sbin/sslsnoop.bt`、`ssllatency.bt`、`bashreadline.bt`，都是 uprobe 的现成例子

**本系列**

- [eBPF 入门](https://suzf.net/zh/blog/posts/ebpf-getting-started/)、[用 eBPF 排查变慢的 Linux 服务器](https://suzf.net/zh/blog/posts/ebpf-troubleshooting-playbook/)
