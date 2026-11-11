---
title: "Terraform Across AWS, Google Cloud and Azure: Layout, Auth, State and CI"
slug: "terraform multi cloud best practices"
date: 2026-03-31T22:54:13+08:00
author: "Jeffrey Su"
description: "How to run Terraform on more than one cloud without making a mess: stacks split by cloud, environment and component, pinned providers and aliases, OIDC instead of access keys, a state backend per cloud, modules that share outputs instead of abstractions, cross-cloud wiring, tags vs labels, plan/apply in CI and drift checks."
categories: ["Skills Matrix"]
tags: ["terraform", "devops", "multi-cloud"]
toc: true
draft: false
---

Terraform's pitch for multi-cloud is that one tool and one language cover AWS, Google Cloud and Azure. That part is true. What it doesn't give you is one *model*: each cloud still has its own identity system, networking, naming rules, quotas and failure modes, and the provider for each one is a thin layer over that cloud's API. Most multi-cloud Terraform trouble comes from pretending otherwise.

This post is the setup I use when one team manages infrastructure on more than one cloud: how to lay out the repository, pin and configure providers, log in from CI without stored keys, store state, design modules, connect the clouds to each other, tag consistently, and run plan and apply safely. The examples were checked with `terraform validate` on Terraform 1.17 with the AWS 6.x, Google 8.x and AzureRM 5.x providers.

<!--more-->

## 1. Decide what "multi-cloud" means for you

"Multi-cloud" covers very different setups, and the right structure depends on which one you have:

- **Different workloads on different clouds.** The data platform runs on Google Cloud for BigQuery, the product runs on AWS, the corporate apps are on Azure. This is the most common case and the easiest: each cloud is mostly independent, with a few shared pieces such as DNS, identity and the network links between them.
- **The same workload on several clouds** for redundancy or customer requirements. Much harder: you need equivalent infrastructure on each side and a way to keep them in step.
- **A migration** from one cloud to another, where both exist for a year or two.

In all three, resist the urge to build a cloud-neutral layer on top of Terraform. A module that creates "a network" on any cloud can only offer what all three have in common, so you lose the features you chose each cloud for, and every cloud-specific need turns into another variable. Share conventions, interfaces and pipelines across clouds; write the resources natively for each one.

## 2. Repository layout: stacks per cloud, environment and component

Split the code into **stacks**: small root modules, each with its own state, that you plan and apply on their own. Divide them by cloud, then environment, then component:

```
infrastructure/
├── modules/                    # reusable modules, versioned
│   ├── aws-network/
│   ├── gcp-network/
│   ├── azure-network/
│   └── ipam/                   # address plan as data, no resources
├── live/
│   ├── aws/
│   │   ├── prod/
│   │   │   ├── network/        # one stack = one state
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
│       ├── dns/                # records pointing at every cloud
│       └── aws-gcp-vpn/        # links that need both sides
└── .github/workflows/
```

Why this shape:

- **Small blast radius.** A plan for `gcp/prod/bigquery` can't touch the AWS network, and a broken provider upgrade in one stack doesn't block the others.
- **Fast plans.** A stack with a few hundred resources plans in seconds. One state with every cloud in it refreshes thousands of resources on every change, and needs credentials for all three clouds every time.
- **Clear ownership.** The CI job, the cloud identity and the code owners can all follow the directory.

Components that change at different rates go in different stacks: the network changes a few times a year, the Kubernetes cluster monthly, application resources daily. Use directories for environments, not workspaces. Environments differ in more than variables (accounts, regions, sizes), and a directory makes it obvious which one you're in. The [Terraform State post](https://suzf.net/en/blog/posts/terraform-state-management-best-practices/#3-splitting-state-directories-not-workspaces) goes into that choice.

Cross-cloud resources, the ones that need *both* clouds' providers, get their own stacks under `global/` instead of being bolted onto one side.

## 3. Providers: pinning, lock files and aliases

Pin every provider to a major version in each stack and in each module:

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

`~> 6.0` allows any 6.x and blocks 7.0, which is where breaking changes go. A stack only lists the providers it uses; an AWS stack has no reason to download the Azure provider.

The constraint picks the range; the **lock file** `.terraform.lock.hcl` pins the exact version and its checksums. Commit it. Without it, two people (or a laptop and CI) can resolve different versions on the same day. The lock file only records checksums for the platform that ran `init`, so if the team uses macOS on ARM and CI runs Linux, generate it for both or CI will fail the checksum check:

```bash
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
```

Upgrade providers on purpose, one stack at a time: `terraform init -upgrade`, read the plan, merge. Tools such as Renovate or Dependabot can open those pull requests for you.

**Aliases** give you more than one configuration of the same provider: another region, another account, another subscription. Since AWS provider 6.0 most resources also accept a `region` argument, so one provider block can manage several regions of the *same* account. For a second account you still need an alias with its own role:

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
  source = "../../modules/aws-peering"
  providers = {
    aws.requester = aws
    aws.accepter  = aws.shared
  }
}
```

A module that needs two configurations declares them with `configuration_aliases = [aws.requester, aws.accepter]` in its `required_providers` block. Don't put `provider` blocks inside reusable modules: the caller decides where things go.

## 4. Authentication: OIDC instead of keys

Three clouds usually means three sets of long-lived credentials stored in CI, each a secret that can leak and has to be rotated. All three clouds now accept short-lived tokens from a CI system's OIDC provider instead, so CI can log in with nothing stored at all:

| Cloud | What you create once | What CI does |
|---|---|---|
| AWS | An IAM OIDC identity provider for your CI and an IAM role that trusts it | Exchanges the CI token for temporary role credentials |
| Google Cloud | A Workload Identity Pool and provider, and a service account it may impersonate | Exchanges the CI token for a short-lived access token |
| Azure | A federated credential on an app registration or user-assigned managed identity | The azurerm provider exchanges the CI token itself (`use_oidc = true`) |

In every case, restrict the trust to your repository and, for production, to the protected branch or environment. A trust policy that accepts any repository in the organisation is the most common mistake here.

Give each stack two identities: a **plan** identity with read-only access, used on pull requests, and an **apply** identity with write access, used only after review. A pull request from a feature branch then can't change anything, whatever the code says. One catch: with locking on, even `plan` writes a lock file to the state backend, so the plan identity needs write access to that one object (on S3 the `<key>.tflock` object next to the state), or PR plans run with `-lock=false`.

On laptops, use each cloud's own login rather than keys: `aws sso login`, `gcloud auth application-default login` and `az login`. The providers pick those credentials up without any configuration in code.

## 5. State: one backend per cloud

Each stack's state goes in a backend on the cloud it manages. Then an outage or permission problem in one cloud doesn't stop you from managing the others, and the people who can read AWS state are the ones who already have AWS access. All three backends support locking:

```hcl
# live/aws/prod/network/backend.tf
terraform {
  backend "s3" {
    bucket       = "acme-tfstate-aws"
    key          = "prod/network/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true # S3-native locking, Terraform 1.10+
    encrypt      = true
  }
}

# live/gcp/prod/network/backend.tf: GCS locks on its own
terraform {
  backend "gcs" {
    bucket = "acme-tfstate-gcp"
    prefix = "prod/network"
  }
}

# live/azure/prod/network/backend.tf: locks with a blob lease
terraform {
  backend "azurerm" {
    resource_group_name  = "tfstate"
    storage_account_name = "acmetfstate"
    container_name       = "tfstate"
    key                  = "prod/network.tfstate"
    use_azuread_auth     = true # Entra ID instead of storage account keys
  }
}
```

Turn on versioning for the S3 bucket and the GCS bucket and soft delete for the Azure container, so a bad write can be rolled back. State holds every attribute of every resource, including secrets, so access to these buckets deserves the same care as access to production itself. The [Terraform State post](https://suzf.net/en/blog/posts/terraform-state-management-best-practices/) covers locking, recovery and keeping secrets out of state in detail.

The bootstrapping question (where does the state of the bucket that holds state go?) has a dull answer: create the three state buckets once from a small stack with local state, commit nothing secret, and don't touch it again.

## 6. Modules: share interfaces, not abstractions

The old advice for multi-cloud modules was one module with a `cloud` variable and a `count` switch in front of an AWS, a GCP and an Azure implementation. In practice that module has to require every cloud's provider, its variables become the union of what each cloud needs, and its behaviour is whatever the least capable cloud can do.

Write one module per cloud instead, and make them **agree on outputs**. Callers and other stacks can then treat the clouds alike where it matters, without hiding what each one is:

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
  value = { for z, s in aws_subnet.private : z => s.id } # zone => subnet
}
```

```hcl
# modules/gcp-network/main.tf
resource "google_compute_network" "this" {
  name                    = var.name
  auto_create_subnetworks = false
}

# GCP subnets are regional: one subnet covers every zone in the region
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

Both modules output `network_id`, `cidr_block` and `private_subnet_ids` keyed by zone, but the GCP one has one regional subnet where AWS has one subnet per zone. That difference is real, so the modules keep it instead of faking per-zone subnets on Google Cloud.

Version shared modules (Git tags or a private registry) and reference a version from each stack: `source = "git::https://github.com/acme/tf-modules.git//aws-network?ref=v3.2.0"`. A change to a module then reaches production one stack at a time, when each one bumps its `ref`.

## 7. Wiring clouds together

Some things need information from more than one cloud: a VPN between AWS and Google Cloud, DNS records pointing at load balancers on both, a firewall rule on one side that allows the other side's range. There are three good ways to pass that information, from simplest to most decoupled.

**Constants in a shared module.** Values that change rarely and that you decide, such as the address plan, belong in a module that has only outputs. Every stack reads the same CIDR blocks from it, which also keeps them from overlapping. (The [VPC CIDR planning post](https://suzf.net/en/blog/posts/planning-vpc-cidr-ranges/) covers how to lay that plan out.)

**Another stack's outputs.** For values Terraform creates, such as IDs and addresses, read the other stack's outputs from its state:

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

The catch is access: to read the outputs, this stack's identity needs read access to the whole state file of the other stack, secrets included.

**A parameter store.** The producing stack writes the few values it wants to share to AWS SSM Parameter Store, Google Secret Manager or Azure App Configuration, and consumers read them with a data source. More setup, but consumers only see what was published.

Whichever you pick, the stack that connects two clouds lives in `global/` and has both providers. When the VPN changes you plan one stack that shows both sides, instead of applying two stacks in the right order and hoping.

## 8. Tags, labels and naming

Consistent metadata is what makes cost reports, ownership lookups and cleanup scripts work across clouds. The three clouds disagree on the details, so decide on one set of keys and translate it per cloud:

| | AWS tags | Google Cloud labels | Azure tags |
|---|---|---|---|
| Keys | Case-sensitive | Lowercase letters, digits, `_` and `-` only | Case-insensitive |
| Values | Any case | Same rules as keys | Any case |
| Limit per resource | 50 | 64 | 50 |
| Set defaults in the provider | `default_tags` | `default_labels` | No: pass `tags` to every resource |

With keys `Project`, `Environment` and `ManagedBy`, the AWS and Azure stacks use them as they are and the Google Cloud stacks use a lowercased version:

```hcl
locals {
  tags = {
    Project     = "shop"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
  # Google Cloud labels only allow lowercase
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

# azurerm has no provider-level default: pass local.tags to each resource
resource "azurerm_resource_group" "main" {
  name     = "shop-prod"
  location = "westeurope"
  tags     = local.tags
}
```

Provider-level defaults mean nobody can forget them on a new resource. Add an `Owner` or `Team` key and a `CostCenter` if finance needs one, and turn the keys on as cost allocation tags or in billing export so the reports can actually group by them.

For names, one pattern such as `{project}-{env}-{component}` works on all three clouds as long as it stays short and lowercase with hyphens. Azure storage accounts (3 to 24 lowercase letters and digits, no hyphens, globally unique) and Google Cloud project IDs (globally unique) are the exceptions that need their own rule.

## 9. CI/CD: plan on PR, apply the saved plan

Every stack goes through the same pipeline: plan on the pull request with the read-only identity, review the plan, then apply that exact plan with the write identity after approval. Here is a GitHub Actions version with one matrix entry per stack, logging in to each cloud with OIDC:

```yaml
name: terraform
on:
  pull_request:
    paths: ["infrastructure/**"]
  push:
    branches: [main]
    paths: ["infrastructure/**"]

permissions:
  id-token: write # lets the job request an OIDC token
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
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3

      - if: matrix.cloud == 'aws'
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_PLAN_ROLE_ARN }}
          aws-region: us-east-1
      - if: matrix.cloud == 'gcp'
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_PLAN_SA }}

      - run: terraform init -input=false
      - run: terraform plan -input=false -out=tfplan
      - uses: actions/upload-artifact@v4
        with:
          name: tfplan-${{ matrix.id }}
          path: infrastructure/${{ matrix.dir }}/tfplan
          retention-days: 3 # the plan file contains secrets
```

The apply job has the same matrix and logins with the apply identities, runs only on `push` to `main`, and adds three things: `needs: plan`, `environment: production` (so a reviewer has to approve it), and a step that downloads `tfplan-${{ matrix.id }}` and runs `terraform apply -input=false tfplan`. Applying the saved file means you apply exactly what was reviewed. If anything changed in between, Terraform refuses to apply a stale plan instead of quietly doing something else.

A few details that matter more with several clouds:

- **Plan only what changed.** On a large repository, build the matrix from the directories a pull request touched (with a path filter action, or a small script over `git diff --name-only`), plus every stack that uses a changed module.
- **One run per stack at a time.** Add `concurrency: tf-${{ matrix.id }}` so two merges don't race on the same state. The lock would stop the second one, but with an error instead of a wait.
- **Make the plan readable.** Post a summary to the pull request: how many resources each stack creates, changes and destroys, with replacements and deletions of stateful resources called out. Paste a plan into the [Terraform Plan Viewer](https://suzf.net/en/tools/terraform-plan-viewer) to see that breakdown.

## 10. Drift detection and policy checks

With several cloud consoles in play, somebody will eventually change something by hand. Find out from a scheduled job, not from the next unrelated pull request that suddenly wants to revert it:

```yaml
on:
  schedule:
    - cron: "0 6 * * 1-5" # 06:00 UTC on weekdays
# same matrix and logins as the plan job, then:
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_wrapper: false # let the step see Terraform's own exit code
      - run: terraform init -input=false
      - run: terraform plan -input=false -lock=false -detailed-exitcode
```

With `-detailed-exitcode`, `plan` exits with 0 when nothing changed, 1 on error and 2 when there are changes. Treat 2 as drift: fail the job and open an issue or send a message to the team that owns the stack. `terraform plan -refresh-only` shows only the differences between state and reality, without the changes your code would make. Then either put the manual change into the code, or let the next apply revert it.

Static checks catch problems before a plan even runs. `terraform fmt -check` and `terraform validate` cost nothing. TFLint with the AWS, Google and AzureRM rulesets catches invalid instance types, deprecated arguments and naming mistakes that `validate` can't see. Checkov or Trivy flag public buckets, open security groups and missing encryption across all three clouds with one tool. Run them in the plan job and fail on errors.

## 11. Checklist

- Write resources natively per cloud; share conventions, outputs and pipelines, not a cloud-neutral layer.
- One stack per cloud, environment and component, each with its own state; cross-cloud links in their own stacks.
- Pin providers to a major version, commit `.terraform.lock.hcl` for every platform you use, upgrade one stack at a time.
- Log in from CI with OIDC; separate read-only plan and write apply identities; restrict trust to your repository and branch.
- Keep each cloud's state on that cloud, with locking and versioning.
- Pass data between stacks through a shared constants module, remote state or a parameter store.
- One set of tag keys, translated into labels on Google Cloud, set as provider defaults where the provider allows it.
- Apply only the reviewed plan file; run one job per stack at a time.
- Check for drift on a schedule and run linters and policy checks on every pull request.
