---
title: "Planning VPC CIDR Ranges: Sizing, Subnets per AZ and Avoiding Overlaps"
slug: "planning vpc cidr ranges"
date: 2026-10-31T10:00:00+08:00
author: "Jeffrey Su"
description: "How to choose CIDR ranges for cloud VPCs so they never collide: inventory what's taken, carve 10.0.0.0/8 top-down by region and environment, size VPCs for Kubernetes pods, split subnets per AZ with Terraform's cidrsubnet, and check for overlaps before you apply."
categories: ["Skills Matrix"]
tags: ["networking", "aws", "terraform", "devops"]
toc: true
draft: false
---

The CIDR block is the first thing you type when you create a VPC and one of the hardest things to change later. Pick `10.0.0.0/16` because the console suggested it, do the same in the next account, and a year later the two VPCs can't be peered, the VPN to the office routes half its traffic into the wrong network, and the only real fix is to rebuild one of them.

This post is the process I use to avoid that: take stock of what is already in use, carve the private address space top-down, size each VPC for what will actually live in it, split it into subnets per availability zone, and check the whole list for overlaps before anything is created. The examples use AWS, with notes for Azure and Google Cloud where they differ.

<!--more-->

## 1. Why the first choice sticks

On AWS a VPC's primary CIDR block can't be changed after creation. You can associate secondary blocks (five per VPC by default, with rules about which ranges can be combined), and subnets can't be resized at all: to make one bigger you create a new subnet and move everything into it. Google Cloud lets you expand a subnet's primary range but never shrink it, and Azure lets you add address ranges to a VNet. None of them can fix the real problem, which is two networks using the same addresses.

Overlaps matter because routing is by destination. A route table can only send `10.0.5.20` one way. If two networks both contain that address, anything that has to reach both of them breaks:

- **VPC peering** refuses to connect VPCs whose CIDR blocks match or overlap.
- **Transit gateways and VPNs** can carry only one route for an address range, so one of the two networks becomes unreachable from the rest.
- **Hosts and containers** send traffic to whichever network their local routes prefer. A Docker bridge on `172.17.0.0/16` quietly captures traffic meant for a partner network in `172.16.0.0/12`.

You rarely see this on day one. It shows up when two teams, two acquisitions or two clouds need to talk, and by then both networks are full of running systems.

## 2. Start with an inventory of what's taken

Before choosing anything new, list every range that already exists or that tools will create without asking. Mine usually looks like this:

- existing VPCs and VNets in every account, subscription and project;
- offices, data centres and the client VPN pool;
- partner and vendor networks you connect to over VPN or Direct Connect;
- container defaults: Docker's `172.17.0.0/16` bridge and its address pools for user-defined networks (more of `172.16.0.0/12`, then `192.168.0.0/16`);
- Kubernetes ranges: kubeadm's default Service range `10.96.0.0/12`, Flannel's `10.244.0.0/16`, Calico's `192.168.0.0/16`, and EKS's Service range (`10.100.0.0/16` or `172.20.0.0/16` if you don't set one);
- overlay networks such as Tailscale, which uses `100.64.0.0/10`;
- home networks of people on the VPN, which are almost always `192.168.0.0/24` or `192.168.1.0/24`.

The last few are why I keep cloud networks inside `10.0.0.0/8` and treat `172.16.0.0/12` and `192.168.0.0/16` as belonging to tools and home routers. They are the ranges that software picks by default, so they are the ones most likely to collide.

## 3. Carve the private range top-down

`10.0.0.0/8` holds 16,777,216 addresses. That sounds like plenty until people start taking `/16`s at random, so give the space a structure first and hand out blocks from it. One layout that has worked well for me: one `/12` per region, one `/16` per environment inside it.

```
10.0.0.0/8        whole organisation
  10.0.0.0/12       us-east-1         10.0.0.0  - 10.15.255.255
    10.0.0.0/16       prod
    10.1.0.0/16       staging
    10.2.0.0/16       dev
    10.3.0.0/16 …     13 more /16s for new accounts
  10.16.0.0/12      eu-west-1         10.16.0.0 - 10.31.255.255
  10.32.0.0/12      ap-southeast-1
  …
  10.240.0.0/12     offices, data centre, client VPN
```

`10.0.0.0/8` splits into 16 blocks of `/12`, and each `/12` into 16 blocks of `/16`, so this allows 16 regions with 16 VPCs each. Change the levels to suit you (by business unit, by account, by cloud), but keep the rule that every block sits inside its parent and nothing is allocated outside the plan.

The payoff is **summary routes**. Because everything in eu-west-1 lives in `10.16.0.0/12`, a VPN or transit gateway needs one route to reach the whole region instead of one per VPC, and a firewall rule can say "anything from eu-west-1" in one line. That only works if the blocks are aligned: `10.0.0.0/16` and `10.1.0.0/16` summarise to `10.0.0.0/15`, but add `10.2.0.0/16` and you need two routes again (`10.0.0.0/15` and `10.2.0.0/16`), because a CIDR block always covers a power of two of addresses starting at a multiple of its size.

Two things to watch when you lay it out:

- If you run kubeadm clusters with the default Service range, `10.96.0.0/12` is taken inside every one of them. Either leave that `/12` out of the plan or set `--service-cidr` to something that is in it.
- Keep a spreadsheet, an IPAM tool (AWS VPC IPAM, NetBox) or a file in Git as the single record of what is allocated. The plan is only as good as the record.

## 4. Size each VPC for what will live in it

On AWS a VPC can be anything from `/16` (65,536 addresses) down to `/28` (16). My default for anything that will run workloads is a full `/16`: private addresses cost nothing, and a VPC that runs out can't grow in place.

The biggest consumer is usually Kubernetes. With the Amazon VPC CNI on EKS, every pod gets a real address from the subnet, not just every node. A cluster with 50 nodes running 30 pods each needs 1,500 pod addresses on top of the nodes, load balancers and endpoints in the same subnets, and that number grows every time someone raises `maxPods` or adds a node group. With prefix delegation the CNI assigns `/28` blocks to each node, so the subnet also needs free, contiguous `/28`s, not just enough scattered single addresses.

If a VPC is already short of space, the usual way out on AWS is a secondary CIDR from `100.64.0.0/10` used only for pods (EKS "custom networking"). Those addresses aren't routed outside the VPC, so they can repeat in every VPC without causing overlaps, and the routable `10.x` range is left for things that need to be reached from elsewhere.

Smaller VPCs make sense when a network really has a fixed, small job: a VPN hub or an inspection VPC. Size those as `/24` or `/22`, still inside the plan.

## 5. Split the VPC into subnets per AZ

Inside the VPC, give each tier (public, private, data) its own contiguous block, and inside each tier one subnet per availability zone. Allocate the largest blocks first so they stay aligned, and leave room in every tier for a fourth zone. Here is a `10.0.0.0/16` laid out that way:

```
10.0.0.0/17     private tier (32,768)
  10.0.0.0/19     private-a     8,187 usable in AWS
  10.0.32.0/19    private-b     8,187
  10.0.64.0/19    private-c     8,187
  10.0.96.0/19    (spare: fourth AZ)
10.0.128.0/21   public tier
  10.0.128.0/24   public-a      251
  10.0.129.0/24   public-b      251
  10.0.130.0/24   public-c      251
10.0.136.0/21   data tier
  10.0.136.0/24   data-a        251
  10.0.137.0/24   data-b        251
  10.0.138.0/24   data-c        251
10.0.144.0/20, 10.0.160.0/19, 10.0.192.0/18   unallocated
```

The private subnets are big because that's where nodes and pods go. Public subnets only hold load balancers and NAT gateways, and the data subnets hold databases and caches, so a `/24` each is plenty. Because each tier is one aligned block, a security group or network ACL can refer to "all private subnets" as `10.0.0.0/17`.

With all nine subnets in place, 39,424 of the 65,536 addresses are still free, as eight blocks: `10.0.96.0/19`, `10.0.131.0/24`, `10.0.132.0/22`, `10.0.139.0/24`, `10.0.140.0/22`, `10.0.144.0/20`, `10.0.160.0/19` and `10.0.192.0/18`. That's the space for a fourth AZ, endpoint subnets, or a new tier later.

In Terraform, compute the subnets from the VPC block with `cidrsubnet(prefix, newbits, netnum)` instead of typing them. `newbits` is how many bits to add to the prefix length and `netnum` is which of the resulting blocks to take:

```hcl
locals {
  vpc_cidr = "10.0.0.0/16"
  azs      = ["us-east-1a", "us-east-1b", "us-east-1c"]

  # /16 + 3 bits = /19: 10.0.0.0/19, 10.0.32.0/19, 10.0.64.0/19
  private = [for i, az in local.azs : cidrsubnet(local.vpc_cidr, 3, i)]
  # /16 + 8 bits = /24, starting at block 128: 10.0.128.0/24, 10.0.129.0/24, 10.0.130.0/24
  public  = [for i, az in local.azs : cidrsubnet(local.vpc_cidr, 8, 128 + i)]
  # block 136 onwards: 10.0.136.0/24, 10.0.137.0/24, 10.0.138.0/24
  data    = [for i, az in local.azs : cidrsubnet(local.vpc_cidr, 8, 136 + i)]
}
```

Keep the `netnum` values fixed per AZ. If you compute subnets from the *length* of a list and someone removes an AZ from the middle, every subnet after it gets a new CIDR, and Terraform will plan to replace them, along with everything inside.

## 6. Reserved addresses and minimum sizes per cloud

Every cloud keeps a few addresses in each subnet for itself, so the usable count is smaller than the textbook "total minus two":

| | Reserved per subnet | Usable in a `/24` | Smallest IPv4 subnet |
|---|---|---|---|
| AWS | 5: the first four and the last | 251 | `/28` (11 usable) |
| Azure | 5: the first four and the last | 251 | `/29` |
| Google Cloud | 4: the first two, the second-to-last and the last | 252 | `/29` |

Some managed services also expect subnets of a fixed size or name. On Azure, `AzureFirewallSubnet` and `AzureBastionSubnet` need a `/26` or larger and `GatewaySubnet` should be at least a `/27`. Plan those blocks with the rest instead of squeezing them into whatever is left.

## 7. Check for overlaps before you apply

A plan in your head or in a spreadsheet still needs checking against reality, especially when the list includes networks other teams own. Put every range that has to reach every other one into a single list and look for overlaps. Here's a realistic one: two regions, a sandbox VPC someone made from the console, the office VPN, an EKS cluster's Service range, Docker's bridge and a partner network.

```
use1-prod         10.0.0.0/16
use1-staging      10.1.0.0/16
euw1-prod         10.16.0.0/16
euw1-sandbox      10.0.0.0/16
office-vpn        10.240.0.0/16
eks-services      172.20.0.0/16
docker-bridge     172.17.0.0/16
partner-network   172.16.0.0/12
```

Three problems:

```
use1-prod 10.0.0.0/16        is the same as   euw1-sandbox 10.0.0.0/16
eks-services 172.20.0.0/16   is inside        partner-network 172.16.0.0/12
docker-bridge 172.17.0.0/16  is inside        partner-network 172.16.0.0/12
```

The first one is the console default doing what it always does (some teams never allocate `10.0.0.0/16` for exactly this reason). The other two are tool defaults that live in `172.16.0.0/12`: neither the EKS cluster nor the Docker hosts will be able to reach the parts of the partner network their own ranges cover.

Checking this by hand is error-prone because blocks of different sizes hide each other: `172.17.0.0/16` doesn't *look* like `172.16.0.0/12`. Two CIDR blocks either don't overlap at all or one is entirely inside the other, so the check is mechanical. I built a free [CIDR Calculator & Overlap Checker](https://suzf.net/en/tools/cidr-calculator) that does it: paste the list (labels and `#` comments are fine) and it reports every duplicate and nested block, plus the summary routes for the whole set. Give it a parent range such as the VPC and it treats the list as that VPC's subnets instead: overlaps become conflicts, anything outside the parent is flagged, and the free space is listed as ready-to-use CIDR blocks, which is how I got the free list in section 5. It runs entirely in the browser.

## 8. When you already have an overlap

The only complete fix is to renumber one of the networks, and that's a migration, not a setting. Before committing to one, these are the ways to live with an overlap, from least to most work:

- **Move the tool, not the network.** Docker's ranges are configurable in `/etc/docker/daemon.json` (`bip` for the default bridge, `default-address-pools` for networks it creates), and Kubernetes Service and pod ranges are set when the cluster is created. Changing these is cheap compared to renumbering a VPC.
- **Expose a service, not a network.** If the overlapping networks only need to reach a few services, AWS PrivateLink (or Private Service Connect on Google Cloud, Private Link on Azure) publishes an endpoint into the other VPC. Addresses never have to be routable between them.
- **Translate addresses.** A private NAT gateway in a non-overlapping "transit" range lets an overlapping VPC reach other networks as if it came from that range. It works, but every flow now goes through NAT, and the networks on the far side can't initiate connections back.
- **Renumber.** Create a new VPC from the plan, move workloads across (or rebuild them with Terraform), and delete the old one. With the plan in place, at least this happens once.

## 9. What about IPv6?

IPv6 mostly removes the problem: an AWS VPC gets a globally unique `/56` from Amazon's pool, which holds 256 subnets of `/64`, so two VPCs never collide. But most environments are still dual-stack, and the IPv4 side has every problem above. Plan IPv4 carefully even if you're adding IPv6, and give every subnet a `/64` so you never have to think about IPv6 subnet sizes.

## 10. Checklist

- Write down every range in use, including Docker, Kubernetes, VPN pools and partner networks.
- Keep cloud networks in `10.0.0.0/8`; leave `172.16.0.0/12` and `192.168.0.0/16` to tools and home routers.
- Allocate top-down from a recorded plan: a block per region, a `/16` per VPC.
- Size VPCs for pods, not just nodes, and leave a spare zone in every tier.
- Compute subnets with `cidrsubnet()` and fixed indexes.
- Remember the reserved addresses: 5 per subnet on AWS and Azure, 4 on Google Cloud.
- Check the full list for overlaps before creating or peering anything.
