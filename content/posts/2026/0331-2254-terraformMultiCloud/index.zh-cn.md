---
title: "用 Terraform 管理 AWS、Google Cloud 和 Azure：目录结构、认证、State 与 CI"
slug: "terraform multi cloud best practices"
date: 2026-03-31T22:54:13+08:00
author: "Jeffrey Su"
description: "在多朵云上用 Terraform 而不搞得一团糟：按云、环境和组件拆分 stack，锁定 Provider 版本并使用别名，用 OIDC 代替访问密钥，每朵云一个 State 后端，模块共享输出而不是抽象，跨云连接，tags 与 labels 的差异，CI 里的 plan/apply，以及漂移检测。"
categories: ["技能矩阵"]
tags: ["terraform", "devops", "multi-cloud"]
toc: true
draft: false
---

Terraform 在多云上的卖点是：一个工具、一种语言就能管 AWS、Google Cloud 和 Azure。这一点没错。但它给不了你一套统一的*模型*：每朵云依然有自己的身份体系、网络、命名规则、配额和故障方式，而每个 Provider 只是对这朵云 API 的一层薄封装。多云 Terraform 的麻烦，大多来自假装这些差异不存在。

这篇文章是一个团队同时管理多朵云时我用的做法：怎样组织仓库、锁定和配置 Provider、让 CI 不存密钥就能登录、存放 State、设计模块、把云和云连起来、统一打标签，以及安全地跑 plan 和 apply。文中的 HCL 示例都用 Terraform 1.17 和 AWS 6.x、Google 8.x、AzureRM 5.x Provider 跑过 `terraform validate`。

<!--more-->

## 1. 先想清楚你的"多云"是哪一种

"多云"涵盖的情况差别很大，合适的结构取决于你是哪一种：

- **不同业务在不同的云上。** 数据平台为了 BigQuery 放在 Google Cloud，产品跑在 AWS，公司内部应用在 Azure。这种情况很常见，也最简单：各朵云基本独立，只有少数共享部分，比如 DNS、身份，以及云之间的网络连接。
- **同一业务跑在多朵云上**，为了冗余或客户要求。难得多：每一边都要有对等的基础设施，还要有办法让它们保持一致。
- **迁移**：从一朵云迁到另一朵，两边要并存一两年。

无论哪种，都不要在 Terraform 之上再造一层"云中立"的抽象。一个能在任何云上创建"网络"的模块，只能提供三朵云的公共部分，于是你当初选每朵云的理由——那些特有功能——全都用不上，而每个云特有的需求都会变成又一个变量。跨云共享的应该是约定、接口和流水线；资源本身按每朵云的原生方式来写。

## 2. 仓库结构：按云、环境和组件拆分 stack

把代码拆成 **stack**：一个个小的根模块，每个都有自己的 State，可以单独 plan 和 apply。先按云，再按环境，再按组件划分：

```
infrastructure/
├── modules/                    # 可复用模块，带版本
│   ├── aws-network/
│   ├── gcp-network/
│   ├── azure-network/
│   ├── aws-peering/            # 需要两套 AWS Provider 配置
│   └── ipam/                   # 地址规划，只有数据，没有资源
├── live/
│   ├── aws/
│   │   ├── prod/
│   │   │   ├── network/        # 一个 stack = 一份 State
│   │   │   ├── eks/
│   │   │   └── data/
│   │   └── staging/
│   ├── gcp/
│   │   └── prod/
│   │       ├── network/
│   │       └── bigquery/
│   ├── azure/
│   │   └── prod/
│   │       └── network/
│   └── global/
│       ├── dns/                # 指向各朵云的 DNS 记录
│       └── aws-gcp-vpn/        # 两边都要动的连接
└── .github/workflows/
```

这样拆的原因：

- **爆炸半径小。** 对 `gcp/prod/bigquery` 的 plan 碰不到 AWS 的网络；某个 stack 里 Provider 升级出了问题，也不会卡住其他 stack。
- **plan 快。** 几百个资源的 stack 几秒就能 plan 完。把所有云塞进一份 State，每次改动都要刷新成千上万个资源，而且每次都要三朵云的凭证。
- **归属清晰。** CI 任务、云上的身份和代码负责人都可以按目录对应。

变化频率不同的组件放进不同的 stack：网络一年改几次，Kubernetes 集群每月改，应用资源天天改。环境用目录区分，不用 workspace。环境之间的差别不只是变量（账号、地域、规格都不同），用目录一眼就能看出当前在哪个环境。[Terraform State 那篇文章](https://suzf.net/zh/blog/posts/terraform-state-management-best-practices/#3-拆分-state用目录而不是-workspace)详细讨论过这个选择。

跨云资源，也就是需要*两边*云 Provider 的资源，放在 `global/` 下自己的 stack 里，而不是硬塞到其中一边。

## 3. Provider：版本锁定、锁文件和别名

在每个 stack 和每个模块里，都把 Provider 锁定到一个大版本：

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    google  = { source = "hashicorp/google", version = "~> 8.0" }
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
  }
}
```

`~> 6.0` 允许任何 6.x，挡住 7.0，而破坏性变更都在大版本里。一个 stack 只列出自己用到的 Provider，AWS 的 stack 没理由去下载 Azure 的 Provider。

版本约束决定范围，**锁文件** `.terraform.lock.hcl` 则锁定确切的版本和校验和。一定要提交它。没有它，两个人（或者笔记本和 CI）同一天可能解析出不同的版本。从公共 registry 下载的 Provider，锁文件里会记录所有平台的校验和，所以在 Mac 上生成的锁文件在 Linux 的 CI 里也能用。但从网络镜像或本地缓存安装的 Provider，只记录执行 `init` 的那个平台的校验和。如果你用了镜像，就要显式加上其他平台，否则 CI 会在校验和检查上失败：

```bash
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
```

Provider 升级要有意为之，一次一个 stack：`terraform init -upgrade`，看 plan，合并。Renovate 或 Dependabot 之类的工具可以替你开这些 PR。

**别名**让同一个 Provider 可以有多套配置：另一个地域、另一个账号、另一个订阅。从 AWS Provider 6.0 起，大多数资源还接受 `region` 参数，所以一个 provider 块就能管理*同一账号*的多个地域。但第二个账号仍然需要一个带自己角色的别名：

```hcl
provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "shared"
  region = "us-east-1"
  assume_role { role_arn = "arn:aws:iam::111111111111:role/terraform" }
}

module "peering" {
  source = "../../../../modules/aws-peering" # 相对于 live/aws/prod/<stack>/
  providers = {
    aws.requester = aws
    aws.accepter  = aws.shared
  }
}
```

需要两套配置的模块，在自己的 `required_providers` 里用 `configuration_aliases = [aws.requester, aws.accepter]` 声明。不要在可复用模块里写 `provider` 块：资源建在哪里，由调用方决定。

## 4. 认证：用 OIDC 代替密钥

三朵云通常意味着 CI 里存着三套长期凭证，每一套都可能泄露、都要轮换。现在三朵云都接受 CI 系统 OIDC 签发的短期令牌，CI 可以什么都不存就完成登录：

| 云 | 一次性要创建的东西 | CI 做什么 |
|---|---|---|
| AWS | 一个对应你 CI 的 IAM OIDC 身份提供商，以及一个信任它的 IAM 角色 | 用 CI 令牌换取该角色的临时凭证 |
| Google Cloud | 一个 Workload Identity 池和提供方，以及一个允许它模拟的服务账号 | 用 CI 令牌换取短期访问令牌 |
| Azure | 应用注册或用户分配托管标识上的联合凭据 | azurerm Provider 自己完成令牌交换（`use_oidc = true`） |

每种情况下，都要把信任限定到你的仓库，生产环境还要限定到受保护的分支或环境。信任策略允许组织里任意仓库，是一个常见又危险的错误。

给每个 stack 两个身份：一个只读的 **plan** 身份，用于 PR；一个可写的 **apply** 身份，只在评审之后使用。这样无论代码写了什么，来自功能分支的 PR 都改不了任何东西。有一个坑：开启锁之后，连 `plan` 都会往 State 后端写锁文件，所以 plan 身份需要对这一个对象有写权限（S3 上就是 State 旁边的 `<key>.tflock`），或者 PR 的 plan 用 `-lock=false` 运行。

在笔记本上，用各家云自己的登录方式，而不是密钥：`aws sso login`、`gcloud auth application-default login` 和 `az login`。Provider 会自动拿到这些凭证，代码里不需要任何配置。

## 5. State：每朵云一个后端

每个 stack 的 State 放在它所管理的那朵云的后端里。这样某朵云出故障或权限出问题时，不影响你管理其他云；能读 AWS State 的人，也正是本来就有 AWS 权限的人。三种后端都支持锁：

```hcl
# live/aws/prod/network/backend.tf
terraform {
  backend "s3" {
    bucket       = "acme-tfstate-aws"
    key          = "prod/network/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true # S3 原生锁，Terraform 1.10+
    encrypt      = true
  }
}

# live/gcp/prod/network/backend.tf：GCS 自带锁
terraform {
  backend "gcs" {
    bucket = "acme-tfstate-gcp"
    prefix = "prod/network"
  }
}

# live/azure/prod/network/backend.tf：用 blob 租约加锁
terraform {
  backend "azurerm" {
    resource_group_name  = "tfstate"
    storage_account_name = "acmetfstate"
    container_name       = "tfstate"
    key                  = "prod/network.tfstate"
    use_azuread_auth     = true # 用 Entra ID 而不是存储账户密钥
  }
}
```

给 S3 和 GCS 存储桶开启版本控制，在 Azure 存储账户上开启 blob 版本控制或软删除，这样一次错误的写入可以回滚。State 里有每个资源的每个属性，包括密钥，所以这些存储桶的访问权限要像生产环境本身一样严格管控。[Terraform State 那篇文章](https://suzf.net/zh/blog/posts/terraform-state-management-best-practices/)详细讲了锁、故障恢复，以及怎样不让密钥进 State。

"存 State 的存储桶，它自己的 State 放哪？"这个自举问题，答案很平淡：用一个使用本地 State 的小 stack 创建三个存储桶，然后加上指向刚建好的存储桶的 backend 块，运行 `terraform init -migrate-state`。这样自举 stack 的 State 也和其他 State 一样放进了存储桶，谁的笔记本上都不会留下本地 State 文件。

## 6. 模块：共享接口，而不是抽象

以前流行的多云模块写法是：一个模块带一个 `cloud` 变量，用 `count` 开关切换背后的 AWS、GCP、Azure 实现。实际上这个模块必须依赖每朵云的 Provider，它的变量会变成每朵云所需变量的并集，而它的能力只能是三者中最弱的那个。

改为每朵云写一个模块，让它们**输出保持一致**。调用方和其他 stack 就能在关键的地方一视同仁地对待各朵云，又不用掩盖每朵云本来的样子：

```hcl
# modules/aws-network/main.tf
resource "aws_vpc" "this" {
  cidr_block = var.cidr_block
  tags       = { Name = var.name }
}

resource "aws_subnet" "private" {
  for_each          = { for i, z in var.zones : z => i }
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.cidr_block, 3, each.value)
  tags              = { Name = "${var.name}-private-${each.key}" }
}

output "network_id" { value = aws_vpc.this.id }
output "cidr_block" { value = aws_vpc.this.cidr_block }
output "private_subnet_ids" {
  value = { for z, s in aws_subnet.private : z => s.id } # 可用区 => 子网
}
```

```hcl
# modules/gcp-network/main.tf
resource "google_compute_network" "this" {
  name                    = var.name
  auto_create_subnetworks = false
}

# GCP 子网是地域级的：一个子网覆盖该地域的所有可用区
resource "google_compute_subnetwork" "private" {
  name                     = "${var.name}-private"
  network                  = google_compute_network.this.id
  region                   = var.region
  ip_cidr_range            = cidrsubnet(var.cidr_block, 3, 0)
  private_ip_google_access = true
}

output "network_id" { value = google_compute_network.this.id }
output "cidr_block" { value = var.cidr_block }
output "private_subnet_ids" {
  value = { for z in var.zones : z => google_compute_subnetwork.private.id }
}
```

两个模块都输出 `network_id`、`cidr_block`，以及按可用区索引的 `private_subnet_ids`，但 GCP 的是一个地域级子网，而 AWS 是每个可用区一个子网。这个差异是真实存在的，所以模块保留它，而不是在 Google Cloud 上伪造出按可用区划分的子网。

共享模块要打版本（Git tag 或私有 registry），每个 stack 引用一个具体版本：`source = "git::https://github.com/acme/tf-modules.git//aws-network?ref=v3.2.0"`。这样模块的改动会随着各个 stack 逐个升级 `ref`，一个一个地进入生产环境。

## 7. 把云和云连起来

有些东西需要多朵云的信息：AWS 和 Google Cloud 之间的 VPN、指向两边负载均衡器的 DNS 记录、一边放行另一边网段的防火墙规则。传递这类信息有三种好办法，从最简单到最解耦：

**共享模块里的常量。** 很少变化、由你决定的值，比如地址规划，放进一个只有输出的模块。每个 stack 都从这里读同一份 CIDR，这也能防止网段重叠。（[VPC 网段规划那篇文章](https://suzf.net/zh/blog/posts/planning-vpc-cidr-ranges/)讲了怎么做这份规划。）

**读取另一个 stack 的输出。** 对于 Terraform 创建出来的值，比如 ID 和地址，从另一个 stack 的 State 里读它的输出：

```hcl
data "terraform_remote_state" "aws_network" {
  backend = "s3"
  config = {
    bucket = "acme-tfstate-aws"
    key    = "prod/network/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "gcp_network" {
  backend = "gcs"
  config = {
    bucket = "acme-tfstate-gcp"
    prefix = "prod/network"
  }
}

resource "google_compute_firewall" "from_aws" {
  name          = "allow-from-aws-prod"
  network       = data.terraform_remote_state.gcp_network.outputs.network_id
  direction     = "INGRESS"
  source_ranges = [data.terraform_remote_state.aws_network.outputs.cidr_block]

  allow {
    protocol = "tcp"
    ports    = ["443", "5432"]
  }
}
```

问题在权限：为了读这些输出，这个 stack 的身份需要能读另一个 stack 的整份 State 文件，包括里面的密钥。

**参数存储。** 生产方 stack 把要共享的少数几个值写进 AWS SSM Parameter Store、Google Secret Manager 或 Azure App Configuration，消费方用数据源读取。配置多一些，但消费方只能看到发布出来的内容。

无论选哪种，连接两朵云的 stack 都放在 `global/` 下，同时拥有两边的 Provider。VPN 有变化时，你 plan 的是一个能同时看到两边的 stack，而不是按顺序 apply 两个 stack 然后祈祷顺序没错。

## 8. 标签、label 与命名

元数据统一，跨云的成本报表、归属查询和清理脚本才能用。三朵云在细节上各不相同，所以先定一套键，再按每朵云转换：

| | AWS tags | Google Cloud labels | Azure tags |
|---|---|---|---|
| 键 | 区分大小写 | 只允许小写字母、数字、`_` 和 `-`；必须以字母开头；最长 63 个字符 | 不区分大小写 |
| 值 | 大小写均可 | 字符规则相同，最长 63；可以为空 | 大小写均可 |
| 每个资源上限 | 50 | 64 | 50 |
| 在 Provider 上设默认值 | `default_tags` | `default_labels` | 不支持：每个资源都要传 `tags` |

用 `Project`、`Environment` 和 `ManagedBy` 作为键，AWS 和 Azure 的 stack 原样使用，Google Cloud 的 stack 用小写版本：

```hcl
locals {
  tags = {
    Project     = "shop"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
  # Google Cloud 的 label 只允许小写
  labels = { for k, v in local.tags : replace(lower(k), "managedby", "managed-by") => lower(v) }
}

provider "aws" {
  region = "us-east-1"
  default_tags { tags = local.tags }
}

provider "google" {
  project        = var.gcp_project
  region         = "europe-west1"
  default_labels = local.labels
}

# azurerm 没有 Provider 级别的默认值：每个资源都传 local.tags
resource "azurerm_resource_group" "main" {
  name     = "shop-prod"
  location = "westeurope"
  tags     = local.tags
}
```

Provider 级别的默认值意味着新资源上谁也忘不了加标签。需要的话再加一个 `Owner` 或 `Team` 键，财务要的话加 `CostCenter`；并在账单设置里把这些键启用为成本分配标签或导出到账单数据，报表才能真正按它们分组。

命名方面，一个像 `{project}-{env}-{component}` 的模式在三朵云上都能用，只要保持简短、小写、用连字符。例外是 Azure 存储账户（3 到 24 个小写字母和数字，不能有连字符，且全局唯一）和 Google Cloud 项目 ID（全局唯一），它们需要单独的规则。

## 9. CI/CD：PR 上 plan，apply 已保存的 plan

每个 stack 走同一条流水线：在 PR 上用只读身份 plan，评审 plan，审批后用可写身份 apply 那份确切的 plan。下面是 GitHub Actions 的写法，每个 stack 一个矩阵项，用 OIDC 登录各朵云：

```yaml
name: terraform
on:
  pull_request:
    paths: ["infrastructure/**"]
  push:
    branches: [main]
    paths: ["infrastructure/**"]

permissions:
  id-token: write # 允许任务申请 OIDC 令牌
  contents: read

jobs:
  plan:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - { id: aws-prod-network, cloud: aws, dir: live/aws/prod/network }
          - { id: gcp-prod-network, cloud: gcp, dir: live/gcp/prod/network }
          - { id: azure-prod-network, cloud: azure, dir: live/azure/prod/network }
    defaults:
      run:
        working-directory: infrastructure/${{ matrix.dir }}
    env:
      ARM_USE_OIDC: "true"
      ARM_CLIENT_ID: ${{ vars.AZURE_PLAN_CLIENT_ID }}
      ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
      ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
    steps:
      - uses: actions/checkout@v7
      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: 1.17.1 # plan 和 apply 用同一个版本

      - if: matrix.cloud == 'aws'
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ vars.AWS_PLAN_ROLE_ARN }}
          aws-region: us-east-1
      - if: matrix.cloud == 'gcp'
        uses: google-github-actions/auth@v3
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_PLAN_SA }}

      - run: terraform init -input=false
      - run: terraform plan -input=false -out=tfplan
      - uses: actions/upload-artifact@v7
        with:
          name: tfplan-${{ matrix.id }}
          path: infrastructure/${{ matrix.dir }}/tfplan
          retention-days: 3 # plan 文件里有密钥
```

apply 任务用同样的矩阵，用 apply 身份登录，只在推送到 `main` 时运行，并多三样东西：`needs: plan`、`environment: production`（这样必须有评审人批准），以及一个下载 `tfplan-${{ matrix.id }}` 并执行 `terraform apply -input=false tfplan` 的步骤。那里也要锁定同样的 `terraform_version`：保存下来的 plan 必须由生成它的那个 Terraform 版本来 apply。apply 已保存的文件，意味着你 apply 的正是评审过的内容。如果中间有另一次 apply 改动了 State，Terraform 会拒绝 apply 这份过期的 plan，而不是悄悄做别的事。但有人在云控制台里做的、没有经过 State 的改动，它是发现不了的，这也是要做漂移检测（见下一节）的又一个原因。

在多云环境下更要注意的几点：

- **只 plan 改动过的部分。** 仓库大了以后，根据 PR 改动的目录构建矩阵（用路径过滤的 Action，或者对 `git diff --name-only` 跑个小脚本），再加上所有用到了被改模块的 stack。
- **每个 stack 同一时间只跑一个。** 加上 `concurrency: tf-${{ matrix.id }}`，两次合并就不会在同一份 State 上竞争。锁也能挡住第二次，但它是直接报错，而不是排队等待。
- **让 plan 好读。** 在 PR 上贴一份摘要：每个 stack 创建、修改、销毁多少资源，并把有状态资源的替换和删除单独标出来。把 plan 粘到 [Terraform Plan 可视化工具](https://suzf.net/zh/tools/terraform-plan-viewer)里就能看到这样的拆解。

## 10. 漂移检测与策略检查

控制台一多，迟早有人手工改东西。要靠定时任务发现它，而不是等到下一个不相干的 PR 突然要把它改回去：

```yaml
on:
  schedule:
    - cron: "0 6 * * 1-5" # 工作日 UTC 06:00
# 矩阵和登录步骤与 plan 任务相同，然后：
      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: 1.17.1
          terraform_wrapper: false # 让步骤拿到 Terraform 自己的退出码
      - run: terraform init -input=false
      - run: terraform plan -input=false -lock=false -refresh-only -detailed-exitcode
```

加上 `-detailed-exitcode` 后，`plan` 无变化时退出码为 0，出错为 1，有变化为 2。`-refresh-only` 只比较 State 和实际情况，不包含你的代码要做的改动，所以这里的 2 几乎都代表漂移，而不是某个已合并、但 apply 失败了的改动。唯一的例外：代码里改了某个根模块输出的定义但还没 apply，这个变化也会出现在 refresh-only 的 plan 里。退出码为 2 时让任务失败，并开一个 issue 或给负责这个 stack 的团队发消息。之后要么把手工改动写进代码，要么让下一次 apply 把它改回去。在同一个定时任务里再跑一次普通的 `plan -detailed-exitcode` 作为第二道检查也有用：它还能发现 `main` 上从未被 apply 的代码。

静态检查能在 plan 之前就发现问题。`terraform fmt -check` 和 `terraform validate` 几乎没有成本。TFLint 配上 AWS、Google 和 AzureRM 的规则集，能抓到 `validate` 看不出来的无效实例类型、已弃用参数和命名错误。Checkov 或 Trivy 用一个工具就能在三朵云上标出公开的存储桶、全开的安全组和缺失的加密。把它们放进 plan 任务，出错就失败。

## 11. 检查清单

- 资源按每朵云的原生方式写；共享约定、输出和流水线，而不是一层云中立的抽象。
- 每个云、环境和组件一个 stack，各有各的 State；跨云连接单独成 stack。
- Provider 锁定到大版本，提交 `.terraform.lock.hcl`（如果从镜像安装，要包含所有平台的校验和），一次升级一个 stack。
- CI 用 OIDC 登录；plan 用只读身份、apply 用可写身份分开；信任限定到你的仓库和分支。
- 每朵云的 State 放在那朵云上，开启锁和版本控制。
- stack 之间通过共享常量模块、远程 State 或参数存储传递数据。
- 一套标签键，在 Google Cloud 上转换为 label，Provider 支持的地方设为默认值。
- 只 apply 评审过的 plan 文件；每个 stack 同一时间只跑一个任务。
- 定时检测漂移，每个 PR 都跑 lint 和策略检查。
