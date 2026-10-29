---
title: "How to Read a Terraform Plan: Replace, Drift and Known After Apply"
slug: "how to read a terraform plan"
date: 2026-10-23T10:00:00+08:00
author: "Jeffrey Su"
description: "What every symbol in terraform plan means, how the Plan: line counts, why a resource is replaced, what drift and (known after apply) tell you, and a checklist before apply."
categories: ["Skills Matrix"]
tags: ["terraform", "devops"]
toc: true
draft: true
---

`terraform plan` is the last moment a mistake is still free. After `apply`, a replaced database is a restored-from-backup database. Most plans are easy to read, but the lines that matter (a `-/+` on something stateful, a note about drift, a count that looks off) are easy to scroll past. This post goes through what each part of a plan means and what to check before you apply.

<!--more-->

To see your own plan laid out this way, paste it into the free [Terraform Plan Viewer](https://suzf.net/en/tools/terraform-plan-viewer) I built. It runs in your browser, puts replacements and drift at the top, and links back to the sections below.

## 1. Save the plan you review

```bash
terraform plan -out=tfplan        # review this
terraform show tfplan             # the same plan, as text
terraform show -json tfplan > plan.json
terraform apply tfplan            # applies exactly what you reviewed
```

Running `terraform apply` without a saved plan computes a new plan, which can differ from the one you read if anything changed in between. In CI, save the plan in the plan job and apply that file in the apply job (see the [CI/CD workflow in the multi-cloud post](https://suzf.net/en/blog/posts/terraform-multi-cloud-best-practices/#6-unified-cicd-workflow)).

The JSON from `terraform show -json` carries more than the text: the exact attribute that forces each replacement, why a resource is deleted, and what drifted. It also contains every value in plain text, sensitive ones included, so treat `plan.json` like the state file.

## 2. The symbols

| Symbol | Meaning |
|---|---|
| `+` | create |
| `~` | update in place |
| `-/+` | destroy, then create a replacement |
| `+/-` | create the replacement first, then destroy (`create_before_destroy`) |
| `-` | destroy |
| `<=` | read a data source during apply |

Inside a resource, `+`, `-` and `~` mark attributes added, removed or changed, and `# (12 unchanged attributes hidden)` folds the rest away. Two entries have no symbol at all: a resource that **has moved to** a new address and one that **will be imported**. Neither changes the real resource on its own.

## 3. How the Plan: line counts

```text
Plan: 1 to import, 4 to add, 2 to change, 2 to destroy.
```

- A replacement counts **twice**: once in "to add", once in "to destroy". Two replacements and nothing else reads `2 to add, 0 to change, 2 to destroy`.
- "to import" appears only when the plan imports something (Terraform 1.5 and later).
- Moves and data source reads aren't counted.

So "to destroy" isn't the number of things you're losing. Subtract the replacements first, then look at what is left.

## 4. Why a resource is replaced

Terraform replaces instead of updating for one of these reasons:

1. **An attribute can't change in place.** The provider decides this, and the plan marks the attribute with `# forces replacement`. A classic example: turning on `storage_encrypted` for an existing `aws_db_instance`. RDS can't encrypt an instance in place, so Terraform destroys it and creates a new, empty one.
2. **The resource is tainted**, from a failed create or `terraform taint`: `is tainted, so must be replaced`.
3. **You asked for it** with `terraform apply -replace=ADDRESS`.
4. **`replace_triggered_by`** pointed at something that changed.

In the JSON, `replace_paths` lists the attributes and `action_reason` says which case it is (`replace_because_cannot_update`, `replace_because_tainted`, `replace_by_request`, `replace_by_triggers`).

For anything that holds data (databases, buckets, disks, keys, DNS zones), a replacement needs a decision, not a glance:

- Can the change be made another way? Many "forces replacement" changes have a migration path, such as a snapshot restored into a new encrypted instance.
- Is there a backup, and does the resource have a final snapshot or deletion protection (`deletion_protection`, `final_snapshot_identifier`)?
- Should it carry `lifecycle { prevent_destroy = true }`, so a plan that would destroy it fails instead?

## 5. (known after apply)

Some values only exist once the provider creates or changes the resource: IDs, ARNs, IP addresses, endpoints. The plan shows them as `(known after apply)`. That's normal for new resources and for attributes computed from changed ones.

It's worth a second look in two cases. When an attribute you expected to stay the same becomes unknown, something it depends on is being replaced. And `<=` data sources read during apply mean their results can't be checked in the plan at all.

## 6. Drift: changed outside Terraform

```text
Note: Objects have changed outside of Terraform
```

During plan, Terraform refreshes each resource and compares it with the state. When someone changed a resource by hand, the plan shows what drifted and then, below it, the changes that would put it back. Applying that plan **undoes the manual change**, which may be exactly what you want, or may revert a hotfix.

To look at drift without proposing anything else, run `terraform plan -refresh-only`. Then either bring the change into the configuration, or let the next apply revert it. Running plan regularly in CI catches drift early ([common pitfalls](https://suzf.net/en/blog/posts/terraform-multi-cloud-best-practices/#8-common-pitfalls)).

## 7. Moves, imports and removals

Configuration blocks now cover the state commands from the [changing state safely](https://suzf.net/en/blog/posts/terraform-state-management-best-practices/#5-changing-state-safely-moved-import-and-removed-blocks):

| Block | Plan shows | Same as |
|---|---|---|
| `moved` (1.1+) | `has moved to` | `terraform state mv` |
| `import` (1.5+) | `will be imported` | `terraform import` |
| `removed` (1.7+) | `will no longer be managed by Terraform` | `terraform state rm` |

A refactor with `moved` blocks should show moves and nothing else. If the same plan also shows the old address being destroyed and the new one created, a `moved` block is missing or its address is wrong.

## 8. Sensitive values

Values marked sensitive show as `(sensitive value)` in the text plan. The saved plan file and `terraform show -json` still contain them in plain text, as does the state ([secrets in state](https://suzf.net/en/blog/posts/terraform-state-management-best-practices/#6-secrets-in-state)). Don't upload `tfplan` or `plan.json` as a public CI artifact, and don't paste a JSON plan into a tool that sends it somewhere.

## 9. Before you apply

- The Plan: line matches what you expected, with replacements counted twice.
- No stateful resource is destroyed or replaced by accident, and each `# forces replacement` is understood.
- Drift is either intended to be reverted or has been brought into the configuration.
- A refactor shows moves, not destroy-and-create.
- You're applying the saved plan file you reviewed.

To go through these on a real plan, paste it into the [Terraform Plan Viewer](https://suzf.net/en/tools/terraform-plan-viewer): it checks most of this list for you.
