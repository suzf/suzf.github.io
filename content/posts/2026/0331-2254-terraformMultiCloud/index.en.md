---
title: "Terraform Multi-Cloud Best Practices"
slug: "terraform multi cloud best practices"
date: 2026-03-31T22:54:13+08:00
author: "Jeffrey Su"
description: ""
categories: ["Skills Matrix"]
tags: ["terraform", "devops", "multi-cloud"]
toc: true
lightgallery: true
draft: false
---

When infrastructure spans AWS, GCP, and Azure, Terraform's management complexity increases dramatically. This post summarizes practical experience in organizing code, managing Providers, and unifying workflows in multi-cloud scenarios.

<!--more-->

### 1. Directory Structure

```
infrastructure/
├── modules/                    # Reusable modules
│   ├── networking/             # Abstract network layer (cross-cloud interface)
│   ├── compute/
│   └── dns/
├── aws/
│   ├── prod/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── providers.tf       # AWS provider config
│   │   └── backend.tf         # S3 backend
│   └── staging/
├── gcp/
│   ├── prod/
│   │   ├── main.tf
│   │   ├── providers.tf       # Google provider config
│   │   └── backend.tf         # GCS backend
│   └── staging/
├── azure/
│   ├── prod/
│   └── staging/
└── global/                     # Cross-cloud resources (DNS, monitoring)
    ├── dns/
    └── monitoring/
```

Core principles:
- Each cloud + each environment = separate directory + separate State
- Minimize blast radius — issues in one cloud don't affect others
- `modules/` holds cross-cloud reusable abstract modules

---

### 2. Provider Management

#### Version Pinning

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

> Always pin Provider versions. In multi-cloud environments, a breaking change in one Provider can cause cascading failures.

#### Authentication Isolation

```hcl
# providers.tf — separate auth config per cloud
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile  # Use named profiles, never hardcode keys
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
  # Use GOOGLE_APPLICATION_CREDENTIALS env var
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
  # Use Azure CLI login or Service Principal
}
```

> Inject credentials via environment variables or profiles — never in code.

---

### 3. Abstract Module Design

The core multi-cloud challenge: the same concept (VPC/network, VM, load balancer) has completely different APIs across clouds.

#### Approach 1: Unified Interface Module (Recommended for Simple Cases)

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

#### Approach 2: Separate Cloud Modules + Unified Outputs (Recommended for Complex Cases)

```hcl
# modules/networking/aws/outputs.tf
output "network_id"  { value = aws_vpc.main.id }
output "subnet_ids"  { value = aws_subnet.main[*].id }

# modules/networking/gcp/outputs.tf
output "network_id"  { value = google_compute_network.main.id }
output "subnet_ids"  { value = google_compute_subnetwork.main[*].id }
```

Unified output interface (`network_id`, `subnet_ids`) — callers don't need to know which cloud is underneath.

---

### 4. State Management Strategy

In multi-cloud environments, State must be isolated by cloud and environment:

| Cloud | Env | Backend | State Key |
|-------|-----|---------|-----------|
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

> Each cloud's State can live on its own cloud (S3 for AWS, GCS for GCP), or be centralized on one cloud. Centralized storage is easier to manage but introduces single-cloud dependency.

---

### 5. Cross-Cloud Resource References

When different clouds need to share data (e.g., AWS IPs needed in GCP firewall rules):

```hcl
# global/dns/main.tf
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

### 6. Unified CI/CD Workflow

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

Key points:
- Matrix strategy runs multi-cloud plans in parallel
- Each cloud/environment gets credentials via separate GitHub Secrets
- Apply stage requires manual approval (`environment: production`)

---

### 7. Variables & Naming Conventions

```hcl
# variables.tf
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

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Cloud       = "aws"  # or gcp / azure
  }
}
```

Cross-cloud naming conventions:
- Resources: `{project}-{env}-{cloud}-{resource}`, e.g., `myproject-prod-aws-vpc`
- Unified tagging: `Project`, `Environment`, `ManagedBy`, `Cloud`
- Enables cost analysis and resource auditing

---

### 8. Common Pitfalls

- **Provider version inconsistency:** Team members using different Provider versions cause State incompatibility. Fix: commit `.terraform.lock.hcl` to Git.

- **Cross-cloud networking:** VPN/Peering configs split across two cloud directories — easy to miss one side. Fix: create a dedicated `cross-cloud/` directory.

- **Credential leakage:** Multi-cloud means multiple credential sets, doubling management complexity. Fix: use Vault or each cloud's Workload Identity Federation to avoid long-lived credentials.

- **Drift detection:** Manual changes are harder to track across multiple clouds. Fix: run `terraform plan` regularly to detect drift, integrate into CI.

- **Cost overruns:** Resources scattered across clouds make it easy to overlook spending. Fix: unified tagging + cost alerts on each cloud.

---
