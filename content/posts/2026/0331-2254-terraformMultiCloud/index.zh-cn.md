---
title: "Terraform 多云管理最佳实践"
slug: "terraform multi cloud best practices"
date: 2026-03-31T22:54:13+08:00
author: "Jeffrey Su"
description: ""
categories: ["技能矩阵"]
tags: ["terraform", "devops", "multi-cloud"]
toc: true
lightgallery: true
draft: false
---

当基础设施跨越 AWS、GCP、Azure 多个云平台时，Terraform 的多云管理复杂度会急剧上升。本文总结在多云场景下组织代码、管理 Provider、统一工作流的实战经验。

<!--more-->

### 1. 目录结构设计

```
infrastructure/
├── modules/                    # 可复用模块
│   ├── networking/             # 抽象网络层（跨云通用接口）
│   ├── compute/
│   └── dns/
├── aws/
│   ├── prod/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── providers.tf       # AWS provider 配置
│   │   └── backend.tf         # S3 backend
│   └── staging/
├── gcp/
│   ├── prod/
│   │   ├── main.tf
│   │   ├── providers.tf       # Google provider 配置
│   │   └── backend.tf         # GCS backend
│   └── staging/
├── azure/
│   ├── prod/
│   └── staging/
└── global/                     # 跨云资源（DNS、监控）
    ├── dns/
    └── monitoring/
```

核心原则：
- 每个云 + 每个环境 = 独立目录 + 独立 State
- 爆炸半径最小化，一个云的问题不影响其他云
- `modules/` 存放跨云复用的抽象模块

---

### 2. Provider 管理

#### 版本锁定

```hcl
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 5.20"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.95"
    }
  }
}
```

> 始终锁定 Provider 版本。多云环境下一个 Provider 的 breaking change 可能导致连锁故障。

#### 认证隔离

```hcl
# providers.tf — 每个云独立配置认证
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile  # 使用 named profile，不硬编码 key
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
  # 使用 GOOGLE_APPLICATION_CREDENTIALS 环境变量
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
  # 使用 Azure CLI 登录或 Service Principal
}
```

> 不同云的凭证通过环境变量或 profile 注入，绝不写在代码里。

---

### 3. 抽象模块设计

多云的核心挑战是：同一个概念（VPC/网络、虚拟机、负载均衡）在不同云上 API 完全不同。

#### 方式一：统一接口模块（推荐简单场景）

```hcl
# modules/compute/main.tf
variable "cloud" {
  type = string
  validation {
    condition     = contains(["aws", "gcp", "azure"], var.cloud)
    error_message = "Supported clouds: aws, gcp, azure"
  }
}

variable "instance_type" { type = string }
variable "name"          { type = string }

# 内部根据 cloud 变量选择不同实现
module "aws" {
  source = "./aws"
  count  = var.cloud == "aws" ? 1 : 0
  name   = var.name
  type   = var.instance_type
}

module "gcp" {
  source = "./gcp"
  count  = var.cloud == "gcp" ? 1 : 0
  name   = var.name
  type   = var.instance_type
}
```

#### 方式二：各云独立模块 + 统一输出（推荐复杂场景）

```hcl
# modules/networking/aws/outputs.tf
output "network_id"  { value = aws_vpc.main.id }
output "subnet_ids"  { value = aws_subnet.main[*].id }

# modules/networking/gcp/outputs.tf
output "network_id"  { value = google_compute_network.main.id }
output "subnet_ids"  { value = google_compute_subnetwork.main[*].id }
```

统一输出接口（`network_id`、`subnet_ids`），上层调用者不关心底层是哪个云。

---

### 4. State 管理策略

多云环境下 State 必须按云和环境隔离：

| 云 | 环境 | Backend | State Key |
|----|------|---------|-----------|
| AWS | prod | S3 | `aws/prod/terraform.tfstate` |
| AWS | staging | S3 | `aws/staging/terraform.tfstate` |
| GCP | prod | GCS | `gcp/prod/terraform.tfstate` |
| Azure | prod | Azure Blob | `azure/prod/terraform.tfstate` |
| Global | DNS | S3 | `global/dns/terraform.tfstate` |

```hcl
# aws/prod/backend.tf
terraform {
  backend "s3" {
    bucket         = "company-terraform-state"
    key            = "aws/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

> 每个云的 State 可以存在各自的云上（AWS 用 S3，GCP 用 GCS），也可以统一存在一个云上。统一存储更便于管理，但引入了对单一云的依赖。

---

### 5. 跨云资源引用

不同云之间需要共享数据时（如 AWS 的 IP 需要配到 GCP 的防火墙）：

```hcl
# global/dns/main.tf — 引用 AWS 和 GCP 的输出
data "terraform_remote_state" "aws_prod" {
  backend = "s3"
  config = {
    bucket = "company-terraform-state"
    key    = "aws/prod/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "gcp_prod" {
  backend = "gcs"
  config = {
    bucket = "company-terraform-state-gcp"
    prefix = "gcp/prod"
  }
}

# 使用两个云的输出
resource "cloudflare_record" "aws" {
  name  = "api-aws"
  value = data.terraform_remote_state.aws_prod.outputs.lb_ip
}

resource "cloudflare_record" "gcp" {
  name  = "api-gcp"
  value = data.terraform_remote_state.gcp_prod.outputs.lb_ip
}
```

---

### 6. CI/CD 工作流统一

```yaml
# .github/workflows/terraform.yml
name: Terraform Multi-Cloud
on:
  pull_request:
    paths:
      - 'infrastructure/**'

jobs:
  plan:
    strategy:
      matrix:
        cloud: [aws, gcp, azure]
        env: [prod, staging]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3

      - name: Terraform Init
        working-directory: infrastructure/${{ matrix.cloud }}/${{ matrix.env }}
        run: terraform init

      - name: Terraform Plan
        working-directory: infrastructure/${{ matrix.cloud }}/${{ matrix.env }}
        run: terraform plan -out=tfplan

      - name: Upload Plan
        uses: actions/upload-artifact@v4
        with:
          name: plan-${{ matrix.cloud }}-${{ matrix.env }}
          path: infrastructure/${{ matrix.cloud }}/${{ matrix.env }}/tfplan
```

关键点：
- 用 matrix 策略并行执行多云 plan
- 每个云/环境的凭证通过 GitHub Secrets 分别注入
- apply 阶段需要人工审批（`environment: production`）

---

### 7. 变量与命名规范

```hcl
# variables.tf — 统一变量命名
variable "project_name" {
  type    = string
  default = "myproject"
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "Must be prod, staging, or dev."
  }
}

# 统一标签/标记
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Cloud       = "aws"  # 或 gcp / azure
  }
}
```

跨云命名约定：
- 资源名：`{project}-{env}-{cloud}-{resource}`，如 `myproject-prod-aws-vpc`
- 统一打标签：`Project`、`Environment`、`ManagedBy`、`Cloud`
- 便于成本分析和资源审计

---

### 8. 常见陷阱

- **Provider 版本不一致：** 团队成员用不同版本的 Provider 导致 State 不兼容。解决：提交 `.terraform.lock.hcl` 到 Git。

- **跨云网络打通：** VPN/Peering 配置分散在两个云的目录中，容易遗漏一端。解决：创建专门的 `cross-cloud/` 目录统一管理。

- **凭证泄露：** 多云意味着多套凭证，管理难度翻倍。解决：使用 Vault 或各云的 Workload Identity Federation，避免长期凭证。

- **Drift 检测：** 多云环境下手动修改更难追踪。解决：定期运行 `terraform plan` 检测漂移，集成到 CI 中。

- **成本失控：** 多云资源分散，容易忽略某个云的费用。解决：统一标签 + 各云的成本告警。

---
