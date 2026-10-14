# Repository delivery workflow

- Use the internal `master` as the development source of truth. Create SDK feature branches from the current internal `master`, complete validation, and submit the internal MR first.
- Resolve remotes by their actual repository URLs before synchronizing. `origin` may name the internal repository in an internal clone; do not infer that it is GitHub from its alias alone.
- Synchronize GitHub only after the corresponding internal change has merged. GitHub sync branches must retain the original internal commits; do not recreate changes by copying files, cherry-picking, squashing, or rebasing the sync commits.
- A GitHub sync PR must contain both its public base and the frozen internal release commit as ancestors, and its complete Git tree must equal that internal commit. Run `Producer/scripts/verify-repository-sync.sh candidate` before submitting it.
- After the GitHub PR merges, run `Producer/scripts/verify-repository-sync.sh published` against the frozen internal release commit and the refreshed GitHub head. Merge commits may differ between platforms; shared ancestry and complete tree equality are the required invariants.
- Release tags in both repositories must resolve to the same frozen internal release commit. Fetch them into separate local namespaces and run `Producer/scripts/verify-repository-sync.sh tags`. Do not treat a version string, matching files without shared ancestry, or a successful branch push as completed repository synchronization.
- The first GitHub sync needs an explicitly reviewed history bridge because the existing masters have unrelated histories. Preserve both histories, retain the validated internal tree, and audit the internal history that will become public; do not force-push either master.
- Follow the current task's authorization for merge, public push, tagging, and publication. A request to push an internal feature branch alone does not authorize those later delivery steps.
- Follow `CONTRIBUTING.md` and `docs/operations/repository-sync.md` for checks and evidence. Preserve unrelated worktree changes and report incomplete validation separately.
