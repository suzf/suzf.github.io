---
title: "Terraform State 团队实践：远程后端、状态锁、重构与故障恢复"
slug: "terraform state management best practices"
date: 2026-03-31T22:17:52+08:00
author: "Jeffrey Su"
description: "团队如何管理 Terraform State：S3 后端与原生状态锁（use_lockfile）、按目录拆分 State、跨配置共享输出、用 moved/import/removed 块代替手工改 State、不让密钥进入 State，以及卡死的锁和失败的 apply 怎么恢复。"
categories: ["技能矩阵"]
tags: ["terraform", "devops"]
toc: true
draft: false
---

Terraform 的 State 文件是它的“记忆”：代码里的每个资源对应哪个真实对象、对象的 ID 和上次已知的属性，都记在这里。一个人在笔记本上跑 Terraform 时，State 很容易被忽略；一旦团队和 CI 流水线共同管理同一套基础设施，几乎所有严重的 Terraform 事故都能追溯到 State：两个 apply 互相覆盖、State 文件随笔记本一起丢了、一次代码重构把生产数据库删掉重建、密码明文躺在存储桶里。

本文是我在团队里用的配置，以及让 State 保持“无聊”的习惯：存在哪里、S3 原生加锁之后状态锁怎么用、怎么拆分、怎么在不手工编辑的情况下修改 State，以及出了问题怎么恢复。

<!--more-->

## 1. State 是什么，为什么必须放在远端

每次 plan，Terraform 都会比较三样东西：你的代码、State、以及（刷新之后的）真实基础设施。State 负责把代码里的 `aws_db_instance.main` 对应到“us-east-1 里那台 ID 为 `db-7f3a…` 的 RDS 实例”。没有它，Terraform 就不知道这台数据库已经存在，会尝试再建一台。

默认情况下 State 是本地的 `terraform.tfstate` 文件。只要涉及两个人，问题就来了：

- 每人一份副本，一个人 apply 之后，另一个人的 State 就过期了；
- 没有任何机制阻止两个 apply 同时执行；
- 文件里有所有资源的所有属性（包括密钥），最终散落在各人的笔记本和备份里；
- 文件一丢，Terraform 就忘了自己管理的一切。资源还在运行，但你得一个个重新 import 回来。

解决办法是**远程后端**：State 存在共享存储里，每次运行都读写同一份，并由后端负责加锁。在 AWS 上就是 S3：

```hcl
terraform {
  required_version = ">= 1.11"

  backend "s3" {
    bucket       = "acme-terraform-state"
    key          = "prod/network/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

存放 State 的桶是唯一不能把自己的 State 存在自己里面的资源。用一个小的引导配置单独创建它（或者手工创建），并打开以后做恢复所需的设置：

```hcl
resource "aws_s3_bucket" "state" {
  bucket = "acme-terraform-state"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # 每次写入都保留上一个版本，这就是你的“撤销键”
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

把已有配置从本地 State 迁到远端：加上 `backend` 块，执行 `terraform init -migrate-state`，Terraform 会把本地 State 复制到桶里。之后跑一次 `terraform plan` 确认，应该显示没有任何变更。

`backend` 块里不能使用变量。要让同一份配置用于多个环境，就把各环境不同的值从块里拿出来，在 init 时从每个环境各自的文件传入：

```bash
terraform init -backend-config=backends/prod.s3.tfbackend
```

## 2. 状态锁：同一时间只允许一个写入者

每次 plan 或 apply 之前，Terraform 会先给 State 加锁，运行结束后释放。期间如果有第二个运行启动，它会报 `Error acquiring the state lock` 并退出，而不是覆盖第一个运行的修改。

**S3 上请使用 `use_lockfile = true`。** 从 Terraform 1.10 开始（1.11 正式可用），S3 后端可以原生加锁：在 State 旁边用条件写入创建一个 `<key>.tflock` 对象，对象已存在时写入就会失败。以前通过 `dynamodb_table` 配置 DynamoDB 表加锁的方式已被标记为弃用。迁移期间可以同时配置两者：Terraform 会同时获取两把锁，新旧版本的使用者都是安全的；等所有人都用上 1.11 及以上版本，再删掉 `dynamodb_table`。执行 Terraform 的 IAM 角色除了 State 文件，还需要对 `.tflock` 对象有 `s3:GetObject`、`s3:PutObject` 和 `s3:DeleteObject` 权限。

其他后端自带加锁：

| 后端 | 加锁方式 |
|---|---|
| S3 | `.tflock` 对象（`use_lockfile`）；DynamoDB 方式已弃用 |
| GCS | 内置，在 State 旁边写一个锁对象 |
| azurerm | 内置，对 State blob 加租约（lease） |
| HCP Terraform / Terraform Enterprise | 内置，同一 workspace 的运行排队执行 |
| Consul | 内置，对 KV 键加 session 锁 |

在 CI 里，多个运行可能重叠，可以让它等待而不是立刻失败：`terraform apply -lock-timeout=10m`。

**锁卡死**通常是运行中途被杀掉、没来得及释放锁：CI 任务在 apply 中途被取消、plan 时合上了笔记本。报错信息里有锁 ID、持有者和加锁时间。先确认那个运行真的已经不在了（看 CI 任务、问当事人），然后：

```bash
terraform force-unlock <LOCK_ID>
```

绝对不要强制解锁一个仍在运行的任务持有的锁，那正是状态锁要防止的竞争。

## 3. 拆分 State：用目录，而不是 Workspace

所有资源放在一个 State 里，意味着每次 plan 都要刷新所有资源（慢），每次 apply 都可能碰到任何东西（险），每个人都需要所有权限。按两个维度拆分：

- **按环境**：prod、staging、dev 绝不共用 State 文件；
- **按层次和变更频率**：网络很少变，一变影响面就很大；应用每天都在变。把它们放进不同的 State，应用发布就碰不到子网。

我常用的目录结构：

```text
infrastructure/
├── modules/                 # 可复用代码，没有自己的 State
│   ├── vpc/
│   └── service/
├── prod/
│   ├── network/             # key: prod/network/terraform.tfstate
│   ├── data/                # 数据库、缓存
│   └── services/
└── staging/
    ├── network/             # key: staging/network/terraform.tfstate
    ├── data/
    └── services/
```

每个叶子目录都是一个独立的根模块，有自己的后端 key。环境之间的差异放在各自的 `.tfvars` 里，也可以引用不同版本的模块，让 staging 先试用模块的新版本，prod 再跟上。

**Workspace**（`terraform workspace new staging`）让一个目录拥有多份 State，S3 后端会把它们存在 `env:/<workspace>/<key>` 下。它适合同一套栈的临时副本，比如每个功能分支或每次测试一份。用来区分 prod 和 staging 就不合适了：两者共用一套后端配置和凭证，挡在你和生产环境之间的只有“当前选中的是哪个 workspace”；环境差异最后会变成散落在代码各处的 `terraform.workspace == "prod" ? … : …`。

## 4. 读取其他配置的输出

State 拆开之后，各层之间需要互相引用：服务层需要网络层的子网 ID。有三种做法，耦合度从高到低：

**`terraform_remote_state`**：直接从对方的 State 读取输出：

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "acme-terraform-state"
    key    = "prod/network/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_instance" "app" {
  subnet_id = data.terraform_remote_state.network.outputs.private_subnet_ids[0]
}
```

简单，但它需要读取对方**整个** State 文件的权限，包括网络层存的所有密钥，还把使用方和提供方的后端结构绑在了一起。

**Provider 数据源**：直接到云上查资源，通常按标签查找。使用方完全不需要访问对方的 State：

```hcl
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "private" }
}
```

**共享参数存储**：提供方把想公开的值写进参数存储（比如 SSM Parameter Store），使用方只读这些值。当很多团队都依赖同一层时，这是最清晰的契约。

我默认用数据源，只在同一个团队自己的各层之间才用 `terraform_remote_state`。

## 5. 安全地修改 State：moved、import 和 removed 块

重构代码会改变资源地址，而 Terraform 是按地址跟踪资源的。把 `aws_instance.web` 改名为 `aws_instance.frontend`，或者挪进一个模块，下一次 plan 就会要求**销毁旧的、新建一个**。如果是数据库，这就意味着停机，甚至丢数据。

以前的做法是在 apply 之前手工执行 `terraform state mv`。Terraform 1.1 到 1.7 陆续加入了专门的配置块，对团队来说在所有关键方面都更好：它们要经过代码评审，会出现在 plan 里，而且会在代码所到的每个环境生效，而不是只在有人记得执行命令的那个环境生效。

**改名或挪进模块：`moved`**（Terraform 1.1+）

```hcl
moved {
  from = aws_instance.web
  to   = module.frontend.aws_instance.this
}
```

plan 里显示的就变成了 `has moved to`，而不是先删后建。所有环境都 apply 之后，这个块也先保留一段时间，因为其他环境或分支可能还停留在旧地址。

**接管手工创建的资源：`import`**（Terraform 1.5+）

```hcl
import {
  to = aws_s3_bucket.logs
  id = "acme-access-logs"
}
```

`terraform plan -generate-config-out=generated.tf` 会帮你生成对应资源块的初稿。整理好之后反复 plan，直到除了 import 之外没有其他变更，再 apply。

**放弃管理但不销毁：`removed`**（Terraform 1.7+）

```hcl
removed {
  from = aws_instance.legacy
  lifecycle {
    destroy = false
  }
}
```

Terraform 会把这个资源从 State 中移除，真实的实例继续运行。把资源移交给另一个配置管理，或者不再由 Terraform 管理时，用的就是它。

State 命令仍然适合查看 State 和做一次性修复：

```bash
terraform state list                         # State 里的所有地址
terraform state show aws_db_instance.main    # 单个资源的属性
terraform state pull > backup.tfstate        # 做危险操作前先拉一份本地副本
terraform state mv  <from> <to>              # 一次性移动；优先用 moved 块
terraform state rm  <address>                # 遗忘但不销毁；优先用 removed 块
```

无论改了什么，都要读 plan。重构之后，只有“0 to add, 0 to change, 0 to destroy”才说明你改对了。想先看清一个大 plan 里有哪些高风险变更，可以把它粘贴进 [Terraform Plan 可视化工具](https://suzf.net/zh/tools/terraform-plan-viewer)。

## 6. State 里的密钥

State 会保存 Terraform 知道的所有属性，其中就包括密钥：你传进去的数据库密码、`tls_private_key` 生成的私钥、`aws_iam_access_key` 创建的访问密钥。把变量或输出标记为 `sensitive = true`，**只是**在 plan 和命令行输出里隐藏它，State 文件和保存下来的 plan 文件里仍然是明文。

把存放 State 的桶当作密钥库来对待：

- **静态加密**：使用 KMS，并且限制谁能使用这把密钥，而不只是谁能读这个桶；
- **限制访问**：只有负责 apply 该环境的 CI 角色和少数应急人员能读生产 State。开发者通常不需要；用数据源（第 4 节）之后，其他配置也不需要；
- **保持版本控制开启**，但用生命周期规则让旧版本过期，因为每个版本都包含当时的密钥；
- **绝不提交 State**：`.gitignore` 里要有 `*.tfstate`、`*.tfstate.*` 和 `.terraform/`。但要提交锁定 Provider 版本的 `.terraform.lock.hcl`；
- **不要公开 plan**：保存的 `tfplan` 和 `terraform show -json` 的输出里同样有敏感值，不要作为公开的 CI 产物上传。

更好的办法是让密钥根本不进入 State：让服务自己生成并保管密钥（比如 RDS 的 `manage_master_user_password = true` 会把密码存在 Secrets Manager 里），传给 Terraform 的是引用而不是值。较新的 Terraform 还提供了**临时资源**（ephemeral resources，1.10+）和**只写参数**（write-only arguments，1.11+，例如支持它的 Provider 上的 `password_wo`），它们只在运行期间使用，不会写入 State 或 plan。

## 7. State 出问题时

**“Error acquiring the state lock”**：有人或别的任务正在运行。等一等，或者看看谁持有锁（报错里有）。确认那个运行已经死掉之后再强制解锁（见第 2 节）。

**有人手工改了基础设施**：plan 里出现了没人在代码里做过的变更。这是配置漂移，不是 State 的问题。先决定以谁为准：要保留手工修改，就改代码去匹配它；要把真实值接受进 State 而不做任何修改，就执行 `terraform apply -refresh-only`，确认前仔细看它要记录的内容。

**apply 执行到一半失败了**：Terraform 每处理完一个资源就保存一次 State，所以 State 与已经创建出来的部分是一致的。修复原因后重新 apply，它会从中断的地方继续。不要先手工删掉建了一半的资源，否则 State 会指向已经不存在的东西。

**State 损坏，或者某次 apply 记录了错误的内容**：这正是开启桶版本控制的意义。找到出问题之前的那个版本并恢复：

```bash
aws s3api list-object-versions --bucket acme-terraform-state \
    --prefix prod/network/terraform.tfstate
aws s3api get-object --bucket acme-terraform-state \
    --key prod/network/terraform.tfstate --version-id <VERSION_ID> restored.tfstate

terraform state push restored.tfstate
```

`state push` 会拒绝 `serial` 比当前 State 小的文件，而旧版本必然更小，所以需要加 `-force`。执行前确认没有其他人正在对这份 State 运行 Terraform，恢复后跑一次 `terraform plan`，确认结果符合预期。

**State 文件丢了，也没有备份**：资源都还在，丢的只是 Terraform 对它们的记录。为每个资源写 `import` 块（第 5 节），plan 到干净为止再 apply。过程很繁琐，这也是开启版本控制最好的理由。

## 8. 团队检查清单

- 每个配置都用远程后端；除了一次性实验，不使用本地 State。
- S3 开启 `use_lockfile = true`、版本控制、KMS 加密并禁止公开访问；State 桶由单独的引导配置管理。
- 每个环境、每个层次一份 State，按目录拆分；Workspace 只用于临时副本。
- 跨团队引用时优先用数据源，而不是 `terraform_remote_state`。
- 重构用 `moved`、`import`、`removed` 块，和其他代码一样经过评审；State 命令只用于查看和应急。
- 生产 State 只有 CI 角色和应急人员可读；尽量不让密钥进入 State。
- apply 在 CI 里执行而不是在笔记本上，带上 `-lock-timeout`，并先评审保存下来的 plan 再 apply。
- 演练过恢复：在真正需要之前，就知道如何把 State 回滚到之前的版本。

## 参考链接

- [Terraform: State](https://developer.hashicorp.com/terraform/language/state)
- [Terraform: S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Terraform: Refactoring with moved blocks](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring)
- [Terraform: Import blocks](https://developer.hashicorp.com/terraform/language/import)
- [Terraform: Removing resources](https://developer.hashicorp.com/terraform/language/resources/syntax#removing-resources)
- [Terraform: Sensitive data in state](https://developer.hashicorp.com/terraform/language/state/sensitive-data)
