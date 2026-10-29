---
title: "读懂 Terraform plan：替换、漂移和 known after apply"
slug: "how to read a terraform plan"
date: 2026-10-23T10:00:00+08:00
author: "Jeffrey Su"
description: "terraform plan 里每个符号的含义、Plan: 行怎么计数、资源为什么会被替换、漂移和 (known after apply) 说明了什么，以及 apply 前的检查清单。"
categories: ["技能矩阵"]
tags: ["terraform", "devops"]
toc: true
draft: true
---

`terraform plan` 是犯错还不用付出代价的最后一刻。apply 之后，被替换的数据库就成了从备份恢复的数据库。大多数 plan 都不难读，但真正要紧的那几行——有状态资源前面的 `-/+`、一条关于漂移的提示、一个看着不对的数字——很容易一滑就过去。本文逐一讲清 plan 各部分的含义，以及 apply 之前要检查什么。

<!--more-->

想把自己的 plan 也按这种方式展开，可以粘贴到我做的免费 [Terraform Plan 可视化工具](https://suzf.net/zh/tools/terraform-plan-viewer)。它在浏览器里运行，把替换和漂移放在最前面，并链接回本文对应的小节。

## 1. 保存你审查过的 plan

```bash
terraform plan -out=tfplan        # 审查这一份
terraform show tfplan             # 同一份 plan 的文本形式
terraform show -json tfplan > plan.json
terraform apply tfplan            # 执行的正是你审查过的内容
```

不带已保存 plan 的 `terraform apply` 会重新计算一份 plan，如果中间有任何变化，它和你看过的那份可能不一样。在 CI 里，plan 任务保存 plan 文件，apply 任务执行这个文件（见[多云实践里的 CI/CD 工作流](https://suzf.net/zh/blog/posts/terraform-multi-cloud-best-practices/#6-cicd-工作流统一)）。

`terraform show -json` 输出的 JSON 比文本多出不少信息：导致替换的具体属性、资源被删除的原因、哪些资源发生了漂移。它也以明文包含所有值，敏感值也不例外，所以要像对待 state 文件一样对待 `plan.json`。

## 2. 各个符号的含义

| 符号 | 含义 |
|---|---|
| `+` | 创建 |
| `~` | 原地更新 |
| `-/+` | 先销毁，再创建替代资源 |
| `+/-` | 先创建替代资源，再销毁（`create_before_destroy`） |
| `-` | 销毁 |
| `<=` | 在 apply 时读取数据源 |

资源内部，`+`、`-`、`~` 分别表示属性被添加、删除或修改，`# (12 unchanged attributes hidden)` 折叠掉其余未变的属性。有两种条目根本没有符号：**has moved to**（地址变了）和 **will be imported**（将被导入）。它们本身都不会改动实际资源。

## 3. Plan: 行是怎么计数的

```text
Plan: 1 to import, 4 to add, 2 to change, 2 to destroy.
```

- 一次替换会被算**两次**：「to add」里一次，「to destroy」里一次。只有两次替换的 plan 会显示 `2 to add, 0 to change, 2 to destroy`。
- 只有 plan 里有导入时才会出现「to import」（Terraform 1.5 及以上）。
- 移动和数据源读取不计入。

所以「to destroy」并不等于你要失去的东西的数量。先减去替换，再看剩下的是什么。

## 4. 资源为什么会被替换

Terraform 选择替换而不是更新，原因只有下面几种：

1. **某个属性无法原地修改。** 这由 provider 决定，plan 会在该属性后面标注 `# forces replacement`。典型例子：给已有的 `aws_db_instance` 打开 `storage_encrypted`。RDS 无法对已有实例原地加密，于是 Terraform 销毁它，再创建一个新的空实例。
2. **资源被标记为 tainted**（创建失败或执行过 `terraform taint`）：`is tainted, so must be replaced`。
3. **你主动要求**，用 `terraform apply -replace=资源地址`。
4. **`replace_triggered_by`** 指向的对象发生了变化。

在 JSON 里，`replace_paths` 列出了这些属性，`action_reason` 说明属于哪种情况（`replace_because_cannot_update`、`replace_because_tainted`、`replace_by_request`、`replace_by_triggers`）。

对任何存数据的资源——数据库、存储桶、磁盘、密钥、DNS 区域——替换都需要认真决定，而不是扫一眼就过：

- 这个改动能不能换一种方式做？很多「forces replacement」都有迁移路径，比如从快照恢复到一个新的加密实例。
- 有没有备份？资源是否开启了最终快照或删除保护（`deletion_protection`、`final_snapshot_identifier`）？
- 要不要加上 `lifecycle { prevent_destroy = true }`，让会销毁它的 plan 直接报错？

## 5. (known after apply)

有些值只有在 provider 创建或修改资源之后才存在：ID、ARN、IP 地址、连接地址。plan 里把它们显示为 `(known after apply)`。对新资源和由变更资源计算出来的属性来说，这很正常。

有两种情况值得多看一眼。原本以为不会变的属性变成了未知，说明它依赖的某个东西正在被替换。而在 apply 时才读取的 `<=` 数据源，意味着它的结果在 plan 里根本无法检查。

## 6. 漂移：在 Terraform 之外被改动

```text
Note: Objects have changed outside of Terraform
```

plan 时 Terraform 会刷新每个资源，再和 state 比较。如果有人手工改过资源，plan 会先列出漂移的内容，再在下面列出把它改回去的变更。执行这个 plan 会**撤销手工改动**——这可能正是你想要的，也可能把一次紧急修复给改回去了。

想只看漂移、不提出其他变更，运行 `terraform plan -refresh-only`。然后要么把这个改动写进配置，要么让下一次 apply 把它改回去。在 CI 里定期跑 plan 可以尽早发现漂移（[常见陷阱](https://suzf.net/zh/blog/posts/terraform-multi-cloud-best-practices/#8-常见陷阱)）。

## 7. 移动、导入和移除

[安全地修改 State](https://suzf.net/zh/blog/posts/terraform-state-management-best-practices/#5-安全地修改-statemovedimport-和-removed-块)里的几个命令，现在都可以用配置块来完成：

| 配置块 | plan 显示 | 相当于 |
|---|---|---|
| `moved`（1.1+） | `has moved to` | `terraform state mv` |
| `import`（1.5+） | `will be imported` | `terraform import` |
| `removed`（1.7+） | `will no longer be managed by Terraform` | `terraform state rm` |

一次用 `moved` 块完成的重构，plan 里应该只有移动。如果同一个 plan 还显示旧地址被销毁、新地址被创建，说明少写了 `moved` 块，或者地址写错了。

## 8. 敏感值

标记为 sensitive 的值在文本 plan 里显示为 `(sensitive value)`。但保存的 plan 文件和 `terraform show -json` 的输出里仍然是明文，state 也一样（[State 里的密钥](https://suzf.net/zh/blog/posts/terraform-state-management-best-practices/#6-state-里的密钥)）。不要把 `tfplan` 或 `plan.json` 作为公开的 CI 构建产物上传，也不要把 JSON plan 粘贴到会把它发送出去的工具里。

## 9. apply 之前

- Plan: 行和预期一致，替换算了两次。
- 没有有状态资源被意外销毁或替换，每一处 `# forces replacement` 都清楚原因。
- 漂移要么确定要改回去，要么已经写进了配置。
- 重构只显示移动，而不是先销毁再创建。
- 执行的是你审查过的那个 plan 文件。

想在真实的 plan 上逐条过一遍，把它粘贴到 [Terraform Plan 可视化工具](https://suzf.net/zh/tools/terraform-plan-viewer)：这份清单里的大部分它都会替你检查。
