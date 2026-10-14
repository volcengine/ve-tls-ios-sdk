# 内部先合入，再同步 GitHub

内部 `master` 是 SDK 开发和交付的主仓。功能先在内部评审、验证并合入；随后建立 GitHub 同步 PR，完成同步校验后发布。GitHub 上收到的外部贡献也先进入内部评审和合入流程，再按同一方式同步。

本流程约束的是每次已完成同步的发布版本。内部先合入、GitHub 尚未同步的窗口里，两端 master 会暂时不同；不能把这段状态描述为已同步。仅修改版本号也不能建立共享历史。

## 两个独立验收条件

| 条件 | 验证方式 |
| --- | --- |
| 同源 | GitHub 同步结果包含冻结的内部发布提交，原提交 ID 和父提交链保留 |
| 内容一致 | 同步候选和同步后的 GitHub head 的完整 Git tree，均与内部发布提交相同 |

完整 tree 比较覆盖源代码、Core vendor、包清单、隐私资源、测试、脚本、文档、路径和文件模式，不设置忽略列表。两端平台生成的 PR merge commit 可以不同，因此不要求两个 master 的 tip SHA 永远相同。发布标签则必须指向同一个内部发布 commit。

## 当前基线

2026-10-13 核对：内部 master 为 `b04e65d`（2.0.0），开源 master 为 `ea10dee`（2.0.1），没有共同祖先，且不是浅克隆。内部 master 的 tree 与开源 2.0.0 提交 `95a9abf` 相同。当前内部 2.0.2 交付分支的初始提交为 `6d68ba8`，MR !11 尚未合入；GitHub 尚未同步此版本。

这些值是当时的核对记录。执行同步时重新 fetch 并确认最新引用，不以本文的历史 SHA 代替现场值。

## 首次历史衔接

1. 完成 2.0.2 验收并合入内部 MR，冻结已合入的内部发布 commit `I`。
2. 核对最新 GitHub master `P`，审阅将公开的内部提交历史。保留同源提交会使其祖先历史一并进入公开仓库。
3. 在单独的同步分支衔接 `I` 和 `P`，保留两个父提交链。以已验收的 `I` 文件树作为完整交付内容，显式审查 GitHub 相对 `I` 的差异，不能无条件忽略开源端的新改动。
4. 验证同步候选同时包含 `I` 和 `P`，且 tree 等于 `I`，再提交 GitHub PR。
5. 使用保留原提交的 merge/fast-forward 方式合入 GitHub；同步 PR 不使用 squash 或 rebase merge。
6. 获取合入后的 GitHub head，验证 `I` 是其祖先且 tree 等于 `I`。通过后，两端开始共享内部发布提交及历史。

首次衔接通过可评审分支和 PR 完成，不重写或强推任一 master。本文和校验脚本不会自动执行衔接、合入或发布。

## 后续同步

1. 从最新内部 master 开发、验证并合入内部 MR，冻结本次内部发布 commit `I`。
2. 获取最新 GitHub base `P`，建立包含两边历史的同步分支；正常同步保留 `I` 的原始提交，不逐文件复制、不 cherry-pick、不 squash/rebase 重建它们。
3. 如 GitHub 出现新的独立代码改动，先纳入内部评审并形成新的冻结提交，再建立同步候选。tree 不相等时停止交付，不能跳过或缩小比较范围。
4. 通过 candidate 校验后提交 GitHub PR；合入后执行 published 校验。
5. 两端发布同一个版本标签，标签均解析为 `I`，再完成包发布并检查实际产物版本与来源。

冻结发布 SHA 很重要：下一批内部开发可能在 GitHub 同步完成前继续前进，不能用不断变化的 master 来检查之前的发布版本。

## 只读校验

先用 `git remote -v` 核对远端身份。本文以 `internal` 表示内部 SDK 仓库（URL 从内部项目配置核对），以 `github` 表示官方 `github.com/volcengine/ve-tls-ios-sdk`。别名可以不同；从内部仓库 clone 时 `origin` 通常指内部，不能把它自动当作 GitHub。按已核对的 URL 替换本文的远端别名。

在当前仓库根运行；参数 `INTERNAL_RELEASE_REF` 应替换为冻结的内部发布 SHA，`sync/producer-v2.0.2` 应替换为实际同步分支。

提交 GitHub 同步 PR 前：

```bash
bash Producer/scripts/verify-repository-sync.sh candidate INTERNAL_RELEASE_REF github/master sync/producer-v2.0.2
```

该检查要求内部发布提交与 GitHub base 都是同步候选的祖先，且候选的 tree 与内部发布提交一致。

GitHub 合入并更新本地远端引用后：

```bash
bash Producer/scripts/verify-repository-sync.sh published INTERNAL_RELEASE_REF github/master
```

该检查要求内部发布提交是 GitHub head 的祖先，且完整 tree 一致。单纯复制文件或 squash 后即使文件内容相同，仍会被拒绝。

发布后，将两个远端的标签取到不同的本地引用，避免同名标签互相覆盖：

```bash
git fetch --no-tags internal refs/tags/v2.0.2:refs/release-check/internal-v2.0.2
git fetch --no-tags github refs/tags/v2.0.2:refs/release-check/github-v2.0.2
bash Producer/scripts/verify-repository-sync.sh tags INTERNAL_RELEASE_REF refs/release-check/internal-v2.0.2 refs/release-check/github-v2.0.2
```

annotated tag 的 tag object 可不同；两边解析出的最终 commit 都必须等于冻结的内部发布 SHA。同一 tree 的另一 commit 也不满足标签验收。

脚本只读本地 Git 对象，不 fetch、push、merge、checkout 或发布。执行者负责先刷新远端引用，确保本地拥有待检查的提交及祖先对象，并在实际写入/合入后重新核对远端 SHA。

脚本通过不替代 SDK 回归、Core vendor 校验、包消费、iOS 运行、隐私声明或实际构建产物验证。脚本目前是仓库交付门禁；只有将其接入必需的 CI 检查及对应分支保护，才能约束人工绕过流程，不能把新增脚本描述为已启用远端强制保护。

脚本自检不访问真实远端：

```bash
bash Producer/scripts/test-support/test-verify-repository-sync.sh
```
