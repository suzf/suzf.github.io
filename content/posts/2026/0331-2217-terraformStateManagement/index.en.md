---
title: "Terraform State for Teams: Remote Backends, Locking, Refactoring and Recovery"
slug: "terraform state management best practices"
date: 2026-03-31T22:17:52+08:00
author: "Jeffrey Su"
description: "How to run Terraform state as a team: an S3 backend with native locking (use_lockfile), splitting state by directory, sharing outputs, moved/import/removed blocks instead of state surgery, keeping secrets out of state, and recovering from a stuck lock or a bad apply."
categories: ["Skills Matrix"]
tags: ["terraform", "devops"]
toc: true
draft: false
---

Terraform's state file is its memory: for every resource in your code it records which real object it manages, with that object's ID and last known attributes. When one person runs Terraform from a laptop, state is easy to ignore. Once a team and a CI pipeline share the same infrastructure, nearly every serious Terraform incident comes back to state: two applies racing each other, a state file lost with a laptop, a refactor that destroys and recreates a production database, or a password sitting in plain text in a bucket.

This post is the setup I use for teams, and the habits that keep state boring: where to store it, how locking works now that S3 locks natively, how to split it, how to change it without hand-editing, and what to do when it goes wrong anyway.

<!--more-->

## 1. What state is, and why it has to be remote

Terraform compares three things on every plan: your configuration, the state, and (after a refresh) the real infrastructure. The state is what turns `aws_db_instance.main` in your code into "the RDS instance `db-7f3a…` in us-east-1". Without it Terraform can't tell that the database already exists and would try to create a second one.

By default state is a local `terraform.tfstate` file. That breaks down as soon as two people are involved:

- each person has their own copy, so one person's apply leaves the other's state stale;
- nothing stops two applies from running at the same time;
- the file holds every attribute of every resource, secrets included, and ends up on laptops and in backups;
- lose the file and Terraform forgets everything it manages. The resources keep running, but you have to import them back one by one.

The fix is a **remote backend**: state lives in shared storage, every run reads and writes the same copy, and the backend handles locking. On AWS that means S3:

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

The state bucket is the one resource that can't keep its state in itself. Create it once in a small bootstrap configuration (with local state you commit nowhere, or created by hand) and give it the settings that make recovery possible later:

```hcl
resource "aws_s3_bucket" "state" {
  bucket = "acme-terraform-state"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # every write keeps the previous version: your undo button
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

To move an existing configuration from local to remote state, add the `backend` block and run `terraform init -migrate-state`. Terraform copies the local state into the bucket. Check the result with `terraform plan`: it should show no changes.

Backend blocks can't use variables. To reuse one configuration across environments, leave the environment-specific values out of the block and pass them at init time from a file per environment:

```bash
terraform init -backend-config=backends/prod.s3.tfbackend
```

## 2. Locking: one writer at a time

Before a plan or apply, Terraform takes a lock on the state and releases it when the run ends. A second run that starts meanwhile fails with `Error acquiring the state lock` instead of writing over the first one's changes.

**On S3, use `use_lockfile = true`.** Since Terraform 1.10 (generally available in 1.11) the S3 backend can lock natively: it writes a `<key>.tflock` object next to the state with a conditional write that fails if the object already exists. The old approach, a DynamoDB table set with `dynamodb_table`, is deprecated. If you are migrating, you can set both options for a while: Terraform takes both locks, so people on old and new versions stay safe. Remove `dynamodb_table` once everyone runs 1.11 or later. The IAM role that runs Terraform needs `s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on the `.tflock` object as well as on the state file.

Other backends lock out of the box:

| Backend | How it locks |
|---|---|
| S3 | `.tflock` object (`use_lockfile`); DynamoDB is deprecated |
| GCS | built in, a lock object next to the state |
| azurerm | built in, a lease on the state blob |
| HCP Terraform / Terraform Enterprise | built in, runs are queued per workspace |
| Consul | built in, a session lock on the KV key |

In CI, where runs can overlap, let a run wait instead of failing at once: `terraform apply -lock-timeout=10m`.

**A stuck lock** happens when a run dies without releasing it: a CI job killed mid-apply, a laptop closed during a plan. The error message shows the lock ID, who holds it and since when. First make sure that run really is gone (check the CI job, ask the person). Then:

```bash
terraform force-unlock <LOCK_ID>
```

Never force-unlock a lock held by a run that is still going. That is exactly the race locking exists to prevent.

## 3. Splitting state: directories, not workspaces

One state for everything means every plan refreshes every resource (slow), every apply can touch anything (risky), and everybody needs permission to everything. Split state along two lines:

- **by environment**: prod, staging and dev never share a state file;
- **by layer and rate of change**: network changes rarely and breaks a lot when it does; applications change daily. Give them separate states so an app deploy can't touch a subnet.

The layout I use:

```text
infrastructure/
├── modules/                 # reusable code, no state of its own
│   ├── vpc/
│   └── service/
├── prod/
│   ├── network/             # key: prod/network/terraform.tfstate
│   ├── data/                # databases, caches
│   └── services/
└── staging/
    ├── network/             # key: staging/network/terraform.tfstate
    ├── data/
    └── services/
```

Each leaf directory is a root module with its own backend key. Environments differ in their `.tfvars`, and they can pin different module versions, so staging can try a module change before prod gets it.

**Workspaces** (`terraform workspace new staging`) give one directory several states; the S3 backend stores them under `env:/<workspace>/<key>`. They work well for short-lived copies of the same stack, such as one per feature branch or per test run. They are a poor fit for prod versus staging: both share one backend configuration and one set of credentials, the only thing between you and prod is which workspace happens to be selected, and differences between environments end up as `terraform.workspace == "prod" ? … : …` scattered through the code.

## 4. Reading another configuration's outputs

Once state is split, layers need each other's values: the services need the network's subnet IDs. There are three ways to get them, from most coupled to least:

**`terraform_remote_state`** reads the other configuration's outputs straight from its state:

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

It's simple, but it needs read access to the **whole** state file, including every secret the network layer stores, and it ties the consumer to the producer's backend layout.

**Provider data sources** look the resource up in the cloud instead, usually by tag. The consumer needs no access to the other state at all:

```hcl
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "private" }
}
```

**A shared parameter store**: the producer writes the values it wants to publish (for example into SSM Parameter Store) and consumers read only those. This is the cleanest contract once many teams depend on one layer.

I default to data sources and reach for `terraform_remote_state` only inside one team's own layers.

## 5. Changing state safely: moved, import and removed blocks

Refactoring code changes resource addresses, and Terraform tracks resources by address. Rename `aws_instance.web` to `aws_instance.frontend`, or move it into a module, and the next plan wants to **destroy the old one and create a new one**. On a database, that's an outage and possibly data loss.

The old fix was to run `terraform state mv` by hand before applying. Terraform 1.1 through 1.7 added configuration blocks for this, and they are better in every way that matters to a team: they go through code review, they show up in the plan, and they apply in every environment the code reaches instead of only where someone remembered to run a command.

**Renaming or moving into a module: `moved`** (Terraform 1.1+)

```hcl
moved {
  from = aws_instance.web
  to   = module.frontend.aws_instance.this
}
```

The plan now says `has moved to` instead of a destroy and a create. Keep the block for a while after it has been applied everywhere, since other environments and forks may still have the old address.

**Adopting a resource created by hand: `import`** (Terraform 1.5+)

```hcl
import {
  to = aws_s3_bucket.logs
  id = "acme-access-logs"
}
```

`terraform plan -generate-config-out=generated.tf` writes a first draft of the matching resource block for you. Tidy it up, then plan until the import shows no other changes before you apply.

**Letting go of a resource without destroying it: `removed`** (Terraform 1.7+)

```hcl
removed {
  from = aws_instance.legacy
  lifecycle {
    destroy = false
  }
}
```

Terraform drops the resource from state and leaves the real instance running, which is what you want when handing a resource over to another configuration or retiring Terraform's management of it.

The state commands are still useful for inspecting state and for one-off fixes:

```bash
terraform state list                         # every address in state
terraform state show aws_db_instance.main    # attributes of one resource
terraform state pull > backup.tfstate        # a local copy before anything risky
terraform state mv  <from> <to>              # one-off move; prefer a moved block
terraform state rm  <address>                # forget without destroying; prefer removed
```

Whatever you change, read the plan. "0 to add, 0 to change, 0 to destroy" after a refactor is the only result that means you got it right. To see the risky changes in a large plan first, paste its JSON into the [Terraform Plan Viewer](https://suzf.net/en/tools/terraform-plan-viewer).

## 6. Secrets in state

State stores every attribute Terraform knows, and that includes secrets: the database password you passed in, the private key generated by `tls_private_key`, an access key created with `aws_iam_access_key`. Marking a variable or output `sensitive = true` hides it from plan and CLI output **only**. It is still in the state file in plain text, and in saved plan files.

Treat the state bucket like a secrets store:

- **encrypt at rest** with KMS, and limit who can use the key, not just who can read the bucket;
- **restrict access**: only the CI role that applies an environment and a small break-glass group should read prod state. Developers usually don't need it, and data sources (section 4) mean consumers don't either;
- **keep versioning on**, but expire old versions with a lifecycle rule, since every version contains the secrets of its day;
- **never commit state**: `.gitignore` should contain `*.tfstate`, `*.tfstate.*` and `.terraform/`. Do commit `.terraform.lock.hcl`, which pins provider versions;
- **don't publish plans**: a saved `tfplan` and `terraform show -json` output contain sensitive values too, so don't upload them as public CI artifacts.

Better still, keep secrets out of state altogether. Let the service generate and keep its own secret (for example `manage_master_user_password = true` on RDS stores the password in Secrets Manager), and pass in references rather than values. Recent Terraform versions also have **ephemeral resources** (1.10+) and **write-only arguments** (1.11+, such as `password_wo` on providers that support it), which are used during the run but never written to state or plan.

## 7. When state goes wrong

**"Error acquiring the state lock".** Someone or something else is running. Wait, or check who holds the lock (the error shows it). Force-unlock only once you are sure that run is dead (section 2).

**Someone changed infrastructure by hand.** The plan shows changes nobody made in code. That's drift, not a state problem. Decide what should win: to keep the manual change, update the code to match; to accept the real values into state without changing anything, run `terraform apply -refresh-only` and read what it records before you confirm.

**An apply failed halfway.** Terraform saves state after each resource, so state matches whatever did get created. Fix the cause and run the apply again; it picks up where it stopped. Don't delete half-created resources by hand first, or state will point at things that no longer exist.

**State is corrupted or an apply recorded something wrong.** This is what bucket versioning is for. Find the version from before the bad run and restore it:

```bash
aws s3api list-object-versions --bucket acme-terraform-state \
    --prefix prod/network/terraform.tfstate
aws s3api get-object --bucket acme-terraform-state \
    --key prod/network/terraform.tfstate --version-id <VERSION_ID> restored.tfstate

terraform state push restored.tfstate
```

`state push` refuses a file whose `serial` is lower than the current state's, which an older version always is, so you'll need `-force`. Make sure nobody else is running Terraform against that state first, then run `terraform plan` and check that it shows what you expect.

**The state file is gone and there is no backup.** The resources still exist; only Terraform's record of them is lost. Write `import` blocks for each one (section 5), plan until it's clean, and apply. It's tedious, which is the best argument for versioning.

## 8. A checklist for teams

- Remote backend for every configuration; no local state outside throwaway experiments.
- S3 with `use_lockfile = true`, versioning, KMS encryption and public access blocked; the state bucket managed in its own bootstrap configuration.
- One state per environment and layer, split by directory; workspaces only for short-lived copies.
- Data sources over `terraform_remote_state` across team boundaries.
- `moved`, `import` and `removed` blocks for refactors, reviewed like any other code; state commands for inspection and emergencies only.
- Prod state readable only by the CI role and a break-glass group; secrets kept out of state where possible.
- Applies run from CI, not laptops, with `-lock-timeout` and a saved plan that is reviewed before it is applied.
- A rehearsed restore: know how to roll state back to a previous version before you need to.

## References

- [Terraform: State](https://developer.hashicorp.com/terraform/language/state)
- [Terraform: S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Terraform: Refactoring with moved blocks](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring)
- [Terraform: Import blocks](https://developer.hashicorp.com/terraform/language/import)
- [Terraform: Removing resources](https://developer.hashicorp.com/terraform/language/resources/syntax#removing-resources)
- [Terraform: Sensitive data in state](https://developer.hashicorp.com/terraform/language/state/sensitive-data)
