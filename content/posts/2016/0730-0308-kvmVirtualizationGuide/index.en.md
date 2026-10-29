---
title: "KVM Virtualization in Practice: From Install to Live Migration"
slug: "kvm virtualization guide"
date: 2016-07-30T03:08:19+08:00
author: "Jeffrey Su"
description: "Day-to-day KVM operations in one guide: checking hardware support, installing libvirt, NAT vs bridged networking, creating VMs with virt-install, setting up virsh console, everyday virsh commands, growing and adding disks with qemu-img, and live migration over shared storage."
categories: ["Skills Matrix"]
tags: ["KVM", "linux"]
toc: true
---

KVM (Kernel-based Virtual Machine) is the virtualization module built into the Linux kernel. Together with QEMU and libvirt it lets one physical machine run several isolated virtual machines. This guide walks through putting a fresh host to work end to end: checking the hardware, installing the stack, networking, creating a VM, the serial console, day-to-day management, growing disks, and finally moving a running VM to another host with live migration.

<!--more-->

All output in this article comes from a 2016 lab where both the hosts and the guests ran CentOS 7:

| Role | Hostname | IP |
|---|---|---|
| Host A | lab.suzf.net | 172.16.5.10 |
| Host B (migration target) | lab2.suzf.net | 172.16.5.20 |
| Virtual machine | hello_kvm | assigned on the bridge |

Everything VM-related lives under `/opt/data/kvm/`. For live migration this directory is shared between the two hosts over NFS:

```text
/opt/data/kvm/
├── disk      # extra data disks
├── images    # system disk images
└── iso       # installation ISOs
```

The commands work largely unchanged on Rocky, Alma and RHEL 8/9; where they differ, the relevant section says so.

## 1. Prepare the host

### 1.1 Check that the CPU supports hardware virtualization

KVM needs the CPU's hardware virtualization extensions: VT-x on Intel (the `vmx` flag) and AMD-V on AMD (the `svm` flag).

```text
# grep -cE 'vmx|svm' /proc/cpuinfo
```

The output is the number of logical CPUs that support virtualization. If it is 0, either the CPU lacks support or virtualization is switched off in the BIOS (usually called Intel Virtualization Technology or SVM Mode). If the host is itself a cloud VM, the provider also has to enable nested virtualization.

### 1.2 Install KVM and libvirt

```text
# yum install -y qemu-kvm libvirt virt-install bridge-utils
# systemctl enable libvirtd
# systemctl start libvirtd
```

Check that the kernel modules are loaded. You should see `kvm` and `kvm_intel` (`kvm_amd` on AMD):

```text
# lsmod | grep kvm
```

Install `virt-manager` as well if you want a graphical front end.

## 2. Networking: NAT or bridge

There are two common ways to connect a KVM guest to the network:

| | NAT (default) | Bridge |
|---|---|---|
| How it works | libvirt creates a `virbr0` virtual switch and guests reach the outside through address translation on the host | The physical NIC is attached to a bridge `br0`, and guests join the physical network like independent machines |
| Guest IP | private address in 192.168.122.0/24 | its own IP on the host's subnet |
| Reachable from outside | No (unless you forward ports) | Yes |
| Setup | works right after install | must be configured by hand |

For a personal lab where guests only need outbound access, NAT is enough. If guests serve traffic, or you plan to live-migrate them (the IP must not change after migration), use a bridge.

### 2.1 Configure a bridge (CentOS 7 network-scripts)

**Step 1**: create the bridge device in `/etc/sysconfig/network-scripts/ifcfg-br0`. The IP address goes on the bridge:

```text
DEVICE="br0"
TYPE="Bridge"
BOOTPROTO=static
IPADDR=10.1.83.205
PREFIX=22
GATEWAY=10.1.80.254
DNS1=59.108.119.3
IPV4_FAILURE_FATAL=yes
IPV6INIT=no
NAME=br0
ONBOOT=yes
DELAY=0
```

**Step 2**: edit the physical NIC in `/etc/sysconfig/network-scripts/ifcfg-eth0`, remove its IP settings and attach it to `br0`:

```text
DEVICE="eth0"
TYPE=Ethernet
BRIDGE="br0"
BOOTPROTO=none
DEFROUTE=yes
IPV4_FAILURE_FATAL=yes
IPV6INIT=no
NAME=system-eth0
ONBOOT=yes
```

NetworkManager at the time did not support bridging, and the Red Hat documentation says to stop NetworkManager or set `NM_CONTROLLED="no"` on the NIC. In my tests `yes` worked fine too, but following the documentation is the safer choice.

**Step 3**: restart networking and check that both the physical NIC and the VM interfaces (`vnetN`) are attached to `br0`:

```text
# systemctl restart network
# brctl show
bridge name     bridge id               STP enabled     interfaces
br0             8000.003048c68ab0       no              eth0
                                                        vnet0
                                                        vnet1
```

Do this from a console (IPMI or a physical terminal): a typo in the config drops your SSH session.

### 2.2 RHEL 8 and later: use nmcli

Newer releases have removed network-scripts, so the bridge is configured through NetworkManager instead. The result is the same as above:

```text
# nmcli con add type bridge ifname br0 con-name br0 \
    ipv4.method manual ipv4.addresses 10.1.83.205/22 \
    ipv4.gateway 10.1.80.254 ipv4.dns 59.108.119.3
# nmcli con add type bridge-slave ifname eth0 master br0
# nmcli con up br0
```

### 2.3 Things to watch with bridges

- The IP lives on the bridge; the bridged physical NIC has no IP of its own.
- Both the bridge and the physical NIC must be up.
- When creating a VM, choose `bridge=br0` for its network.
- Guest IPs must be on the same subnet as the host.

## 3. Create a virtual machine

There are two ways to create a VM: the graphical virt-manager and the command-line virt-install.

### 3.1 virt-manager

virt-manager is a graphical manager built on libvirt and a good way to learn the options when you are starting out. The first time, you need to:

1. connect to localhost (`qemu:///system`);
2. set up a virtual network: the default is the NAT network `default`, or pick the bridge built in the previous section;
3. create or add a storage pool, either a logical volume or a directory of image files.

After that, follow the wizard.

### 3.2 virt-install

virt-install can be scripted, and with a Kickstart file it can install machines unattended and in bulk. Run it as root; `virt-install --help` lists every option.

**Install from a local ISO**, finishing the installer over VNC:

```text
virt-install \
--connect qemu:///system \
--name kvm_node_name \
--ram 512 \
--vcpus 1 \
--hvm \
--disk path=/opt/data/kvm/images/kvm_node_name.img,size=10 \
--os-type linux \
--os-variant rhel7 \
--network bridge=br0 \
--noautoconsole \
--graphics vnc,listen=0.0.0.0 \
--location=/opt/data/kvm/iso/CentOS-7-x86_64-Minimal-1503-01.iso
```

`--graphics vnc,listen=0.0.0.0` makes VNC listen on every interface, which is only acceptable in an internal lab. In production listen on 127.0.0.1 and connect through an SSH tunnel. `virsh vncdisplay kvm_node_name` shows the VNC port.

**Install from a network mirror** without graphics, running the installer on the serial console:

```text
virt-install \
--name smile \
--ram 512 \
--vcpus 1 \
--disk path=/opt/data/kvm/images/smile.img,size=10 \
--os-type linux \
--os-variant rhel7 \
--network bridge=br0 \
--graphics none \
--console pty,target_type=serial \
--extra-args 'console=ttyS0,115200n8 serial' \
--location=http://mirrors.163.com/centos/6.7/os/x86_64/
```

**Unattended install**: pass the Kickstart file's location to the installer with `--extra-args`:

```text
--extra-args="ks=ftp://lab.suzf.net/ks/myks.cfg"
# or
--extra-args "ks=file:/myks.cfg"
```

**Set the serial console at the same time**:

```text
--console pty,target_type=serial \
--extra-args='console=tty0 console=ttyS0,115200n8 serial'
```

`osinfo-query os` lists the valid `--os-variant` values. Newer virt-install versions deprecate `--os-type` in favour of `--osinfo` (for example `--osinfo rhel9.0`).

## 4. Set up virsh console

Connecting to every VM over VNC gets tedious. With a serial console configured, one `virsh console` on the host logs you into the guest, which is especially handy when a network misconfiguration has locked you out of SSH.

**On the host**: the VM's XML needs a `pty` serial port and console. VMs created by virt-install have them by default; if yours doesn't, add them with `virsh edit`:

```text
[root@lab.suzf.net ~]# grep -A 2 -n pty /etc/libvirt/qemu/hello_kvm.xml
88:    <serial type='pty'>
89-      <target port='0'/>
90-    </serial>
91:    <console type='pty'>
92-      <target type='serial' port='0'/>
93-    </console>
```

**In the guest**:

1. Allow root to log in on `ttyS0` (CentOS 7 already allows it):

   ```text
   [root@hello-kvm ~]# grep ttyS0 /etc/securetty || echo "ttyS0" >> /etc/securetty
   ```

2. Send kernel console output to the serial port by adding `console=ttyS0` to the kernel command line. On grub2 systems, edit `/etc/default/grub`, append `console=ttyS0,115200n8` to `GRUB_CMDLINE_LINUX`, and send the grub menu to the serial port too:

   ```text
   [root@hello-kvm ~]# echo 'GRUB_TERMINAL="serial console"
   GRUB_SERIAL_COMMAND="serial --speed=115200"' >> /etc/default/grub
   [root@hello-kvm ~]# grub2-mkconfig -o /boot/grub2/grub.cfg
   ```

   Then confirm that `console=ttyS0` is on the kernel line:

   ```text
   [root@hello-kvm ~]# grep ttyS0 /etc/grub2.cfg
   linux16 /vmlinuz-3.10.0-229.el7.x86_64 root=/dev/mapper/centos-root ro rd.lvm.lv=centos/root rd.lvm.lv=centos/swap crashkernel=auto rhgb quiet LANG=en_US.UTF-8 console=ttyS0
   ```

   Older SysV init systems (such as CentOS 5) also need a getty on the serial port in `/etc/inittab` (untested):

   ```text
   echo "S0:12345:respawn:/sbin/agetty ttyS0 115200" >> /etc/inittab
   ```

3. Reboot the guest.

**Test it**:

```text
[root@lab.suzf.net ~]# virsh console hello_kvm
Connected to domain hello_kvm
Escape character is ^]

[root@hello-kvm ~]# cat /etc/centos-release
CentOS Linux release 7.1.1503 (Core)
```

If no prompt appears after connecting, press Enter. Press `Ctrl + ]` to leave the console.

## 5. Day-to-day management: common virsh commands

`<vm>` below can be the VM's name, ID or UUID.

**Inspecting**

| Command | What it does |
|---|---|
| `virsh list --all` | List all VMs, including stopped ones |
| `virsh dominfo <vm>` | CPU, memory, state and other details |
| `virsh domid <vm>` / `virsh domname <vm>` / `virsh domuuid <vm>` | Convert between name, ID and UUID |
| `virsh vncdisplay <vm>` | Show the VNC port |
| `virsh domblklist <vm>` | List the VM's disks |
| `virsh domiflist <vm>` | List the VM's network interfaces |

**Power**

| Command | What it does |
|---|---|
| `virsh start <vm>` | Start |
| `virsh shutdown <vm>` | Clean shutdown (sends an ACPI power signal to the guest) |
| `virsh reboot <vm>` | Clean reboot |
| `virsh destroy <vm>` | Hard power-off, like pulling the plug; data can be lost |
| `virsh suspend <vm>` / `virsh resume <vm>` | Pause / resume (memory is kept, resources are not freed) |
| `virsh save <vm> <file>` / `virsh restore <file>` | Save the running state to a file / restore from it |
| `virsh autostart <vm>` / `virsh autostart --disable <vm>` | Start / stop starting the VM when the host boots |

**Configuration**

| Command | What it does |
|---|---|
| `virsh edit <vm>` | Edit the XML in your editor; it is validated on save and applies at the next start |
| `virsh dumpxml <vm> > vm.xml` | Export the XML |
| `virsh define /path/to/vm.xml` | Define (register) a VM from XML |

Don't edit the XML files under `/etc/libvirt/qemu/` directly: libvirtd doesn't pick up manual edits and overwrites them the next time it saves. Either use `virsh edit`, or edit a copy and register it again with `virsh define`.

**Delete a VM completely**:

```text
# virsh destroy  <vm>
# virsh undefine <vm>
# rm -f /var/lib/libvirt/images/<vm>.img
```

`undefine` only removes the definition, not the disk image. Newer libvirt can remove both with `virsh undefine <vm> --remove-all-storage`.

## 6. Disk management

### 6.1 Inspect and create disk images

`qemu-img info` shows an image's format, virtual size and actual usage:

```text
# qemu-img info /opt/data/kvm/images/hello_kvm.img
image: /opt/data/kvm/images/hello_kvm.img
file format: qcow2
virtual size: 10G (10737418240 bytes)
disk size: 1.1G
cluster_size: 65536
Format specific information:
    compat: 1.1
    lazy refcounts: true
```

qcow2 allocates space on demand: the virtual size is 10G but the file only uses 1.1G. To create a new 20G image:

```text
# qemu-img create -f qcow2 ubuntu.img 20G
```

### 6.2 Grow the system disk (qcow2 + LVM + XFS)

Here hello_kvm's system disk grows from 10G to 15G and the new space goes to the root filesystem. There are three layers: grow the image, partition inside the guest, then grow LVM and the filesystem.

**Step 1: grow the image** (this method needs the VM shut down):

```text
# virsh shutdown hello_kvm
# qemu-img resize /opt/data/kvm/images/hello_kvm.img +5G
Image resized.
# qemu-img info /opt/data/kvm/images/hello_kvm.img | grep virtual
virtual size: 15G (16106127360 bytes)
# virsh start hello_kvm
# virsh console hello_kvm
```

Back up the image before resizing. To avoid downtime, run `virsh blockresize hello_kvm vda 15G` while the VM is running instead; the guest kernel sees the new size immediately.

**Step 2: partition the new space inside the guest**. Strictly, you should use `t` to set the partition type to `8e` (Linux LVM) before writing, but leaving the default 83 doesn't stop `pvcreate` later, which is what this lab did:

```text
[root@hello-kvm ~]# fdisk /dev/vda
Command (m for help): n
Partition type:
   p   primary (2 primary, 0 extended, 2 free)
   e   extended
Select (default p): p
Partition number (3,4, default 3):
First sector (20971520-31457279, default 20971520):
Last sector, +sectors or +size{K,M,G} (20971520-31457279, default 31457279):
Partition 3 of type Linux and of size 5 GiB is set

Command (m for help): p
   Device Boot      Start         End      Blocks   Id  System
/dev/vda1   *        2048     1026047      512000   83  Linux
/dev/vda2         1026048    20971519     9972736   8e  Linux LVM
/dev/vda3        20971520    31457279     5242880   83  Linux

Command (m for help): w
WARNING: Re-reading the partition table failed with error 16: Device or resource busy.
The kernel still uses the old table. The new table will be used at
the next reboot or after you run partprobe(8) or kpartx(8)
```

The system disk is in use, so the kernel couldn't re-read the partition table. Run `partprobe` to pick up the new partition (reboot if that doesn't work):

```text
[root@hello-kvm ~]# partprobe
```

**Step 3: grow LVM and the filesystem**. Turn the new partition into a physical volume and add it to the `centos` volume group:

```text
[root@hello-kvm ~]# pvcreate /dev/vda3
  Physical volume "/dev/vda3" successfully created
[root@hello-kvm ~]# vgextend centos /dev/vda3
  Volume group "centos" successfully extended
[root@hello-kvm ~]# vgs
  VG     #PV #LV #SN Attr   VSize  VFree
  centos   2   2   0 wz--n- 14.50g 5.04g
```

Add 2G to the root logical volume, then grow the filesystem: `xfs_growfs` for XFS, `resize2fs` for ext4. Both work online while the filesystem is mounted:

```text
[root@hello-kvm ~]# lvextend -L +2G /dev/mapper/centos-root
  Size of logical volume centos/root changed from 8.47 GiB (2168 extents) to 10.47 GiB (2680 extents).
  Logical volume root successfully resized
[root@hello-kvm ~]# xfs_growfs /dev/mapper/centos-root
...
data blocks changed from 2220032 to 2744320

# for ext4:
[root@hello-kvm ~]# resize2fs /dev/mapper/centos-root
```

`lvextend -r` grows the filesystem together with the logical volume, saving the last step. XFS can grow but never shrink, so leave yourself headroom when allocating.

### 6.3 Add a data disk

Create the image on the host first:

```text
# mkdir -p /opt/data/kvm/disk
# qemu-img create -f qcow2 /opt/data/kvm/disk/hello_kvm.qcow2 5G
```

Then run `virsh edit hello_kvm` and add a `<disk>` inside `<devices>`, with a target device name that doesn't clash with existing disks:

```text
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2'/>
  <source file='/opt/data/kvm/disk/hello_kvm.qcow2'/>
  <target dev='vdb' bus='virtio'/>
</disk>
```

The disk appears after a shutdown and start (`virsh reboot` doesn't reload the XML). You can also hot-plug it without downtime and save it to the config in one go:

```text
# virsh attach-disk hello_kvm /opt/data/kvm/disk/hello_kvm.qcow2 vdb \
    --driver qemu --subdriver qcow2 --persistent
```

The guest now sees `/dev/vdb`. From here it's an ordinary disk: format it, add it to `/etc/fstab`, mount it.

```text
[root@hello-kvm ~]# fdisk -l /dev/vdb
Disk /dev/vdb: 5368 MB, 5368709120 bytes, 10485760 sectors

[root@hello-kvm ~]# mkfs.xfs /dev/vdb
[root@hello-kvm ~]# mkdir /data
[root@hello-kvm ~]# echo '/dev/vdb /data xfs defaults 0 0' >> /etc/fstab
[root@hello-kvm ~]# mount -a
```

## 7. Live migration

Live migration moves a running VM from one host to another. Memory pages are copied to the target in successive rounds, and the guest pauses only for a brief moment at the final switchover, so services and network connections inside it carry on almost undisturbed. This lets you repair or upgrade physical servers without taking workloads down.

Below, hello_kvm moves from lab.suzf.net to lab2.suzf.net.

### 7.1 Prerequisites

- **Shared storage**: both hosts must reach the VM's disks at the same path. Fibre Channel LUNs, iSCSI, FCoE, NFS, GFS2 and SCSI RDMA all work; this lab uses NFS.
- libvirtd runs on both hosts, and the source host can SSH into the target.
- The VM uses bridged networking, and the bridge has the same name (`br0`) on both hosts.
- Ideally both hosts have the same CPU model; at minimum the target must support every CPU feature the VM uses.

### 7.2 Set up shared storage

On lab.suzf.net, export `/opt/data/kvm` over NFS:

```text
[root@lab.suzf.net ~]# echo "/opt/data/kvm 172.16.5.0/24(rw,no_root_squash,sync)" >> /etc/exports
[root@lab.suzf.net ~]# systemctl restart nfs-server.service
[root@lab.suzf.net ~]# exportfs -av
exporting 172.16.5.0/24:/opt/data/kvm
```

On lab2, mount it at the same path:

```text
[root@lab2 ~]# showmount -e lab.suzf.net
Export list for lab.suzf.net:
/opt/data/kvm 172.16.5.0/24

[root@lab2 ~]# mount -t nfs4 lab.suzf.net:/opt/data/kvm /opt/data/kvm
[root@lab2 ~]# df -Th | grep nfs
lab.suzf.net:/opt/data/kvm nfs4       50G  3.2G   47G   7% /opt/data/kvm
```

### 7.3 Migrate

Make sure the VM is running:

```text
[root@lab ~]# virsh list --all
 Id    Name                           State
----------------------------------------------------
 2     hello_kvm                      running
```

Start the migration; `--verbose` shows progress:

```text
[root@lab ~]# virsh migrate --live --verbose hello_kvm qemu+ssh://lab2.suzf.net/system
root@lab2.suzf.net's password:

[root@lab ~]#
```

How long it takes depends on the VM's memory size, how fast it dirties pages and the network bandwidth. Keep a `ping` running inside the guest to watch: you usually lose a packet or two at most.

### 7.4 Verify and persist on the target

```text
[root@lab2 ~]# virsh list --all
 Id    Name                           State
----------------------------------------------------
 2     hello_kvm                      running
```

The VM now runs on lab2, but lab2 has no config file for it, so it would "disappear" as soon as it shut down:

```text
[root@lab2 ~]# find /etc/ -name "hello_kvm*"
[root@lab2 ~]#
```

Export the XML and define the VM:

```text
[root@lab2 ~]# virsh dumpxml hello_kvm > /etc/libvirt/qemu/hello_kvm.xml
[root@lab2 ~]# virsh define /etc/libvirt/qemu/hello_kvm.xml
Domain hello_kvm defined from /etc/libvirt/qemu/hello_kvm.xml
```

The easier way is to add `--persistent --undefinesource` when migrating: the VM is defined persistently on the target and its definition is removed from the source, all in one step:

```text
# virsh migrate --live --persistent --undefinesource --verbose \
    hello_kvm qemu+ssh://lab2.suzf.net/system
```

## 8. Troubleshooting

**The VM ignores `virsh shutdown`**

`shutdown` and `reboot` send an ACPI power signal to the guest, and something inside the guest has to handle it. Minimal installs of CentOS 6 and earlier need acpid:

```text
yum install -y acpid
service acpid start
chkconfig acpid on
```

Alternatively, install `qemu-guest-agent` in the guest and use `virsh shutdown <vm> --mode agent`. If nothing works, `virsh destroy` forces it off.

**`virsh console` connects but shows nothing**

Press Enter first. If there's still nothing, check that the guest's kernel command line has `console=ttyS0` (`cat /proc/cmdline`) and that the XML has a `pty` serial port; see section 4.

**XML changes don't take effect**

`virsh edit` changes the persistent config, which applies on the VM's next cold start. `virsh reboot` reboots inside the guest and doesn't reload the XML; you need `shutdown` followed by `start`.

**Migration fails with a CPU incompatibility**

The target host lacks a CPU feature the VM is using. Give the VM a generic CPU model both hosts support (`<cpu mode='custom'>` in the XML), or migrate towards the host with the newer CPU.

## References

- [Live migration with libvirt — chenyudong.com](https://www.chenyudong.com/archives/virsh-kvm-live-migration-with-libvirt.html)
- [libvirt: virsh command reference](https://www.libvirt.org/manpages/virsh.html)
- [virt-install manual](https://github.com/virt-manager/virt-manager/blob/main/man/virt-install.rst)
