---
name: fork-release-rebase
description: Rebase the radomirml/t3code fork branches and the combined monitor branch onto a new upstream stable release, report upstream features that could replace a fork branch, and build the t3-work server release. Use when a new T3 Code stable version is out or the user asks to rebase the fork, update monitor, or prepare a t3-work release.
---

# Rebase the fork onto a stable release

This checkout is the fork (`origin` = radomirml/t3code, `upstream` = pingdotgg/t3code).
Each fork change is one commit on its own branch off the latest stable tag.
`monitor` is the tag plus all of them, and the t3-work server runs it from this
checkout's `apps/server/dist` and `node_modules`. [branches.txt](branches.txt)
lists the branches, their base, and what the task monitor loses without each one.

Goal: stay as close to upstream as possible. Drop a fork branch once upstream
covers it, but only after the user agrees, since the task monitor may need a change.

## 1. Pick the release

`gh release list -R pingdotgg/t3code --exclude-pre-releases -L 3`. The newest is the
target unless the user named one. Skip nightly, preview and mobile tags. If the minor
version jumps (0.1.x to 0.2.x), confirm with the user before going on.

## 2. Check what upstream now covers

For each branch in branches.txt, decide keep, replace or watch:

- Read the release notes (`gh release view <tag> -R pingdotgg/t3code`) and grep them
  for the branch's area. Many entries; grep, don't read them all.
- Look at the files the branch touches (`git show --stat <branch>`) at the new tag.
  Upstream may have added the same field, flag or env var under another name.
- Search upstream PRs for the feature, merged and open
  (`gh pr list -R pingdotgg/t3code --state all --search "<keywords>"`). Last known open
  candidates: #32333 (environment label), #31659 (`t3 pair --base-url`), #33559
  (advertise a proxied https address). Check whether they merged.

A near match is not a replacement. Say exactly what upstream's version does not do.
For a real replacement, say what the task monitor would have to change (branches.txt,
then `task_monitor/controllers/t3.py` in `~/fl3xx/my-tasks-monitor`). Do not drop the
branch yourself.

## 3. Rebase

From the main checkout, run
`.agents/skills/fork-release-rebase/scripts/prepare.sh <tag>`. It fetches upstream, saves `backup/pre-<tag>/*`
branches, makes the scratch worktree `../t3code-rebase-<tag>`, and tries each branch:
clean ones land as `<branch>-rb`, conflicts are listed and aborted. It also prints
monitor's commits.

Work only in the scratch worktree. The main checkout serves the running t3-work
server; do not touch it until step 6.

- **Conflicts.** In the scratch worktree, `git checkout --detach <tag>`, cherry-pick
  the branch, resolve, `git branch -f <branch>-rb HEAD`. Keep both sides' intent;
  upstream often only added an import next to ours. If upstream rewrote the code our
  change sits in, port the change and tell the user what changed in it.
- **monitor.** `git checkout --detach <tag>`, then cherry-pick monitor's commits in
  order (`git rev-list --reverse <old-tag>..monitor`). On a conflict, take the file
  from the matching `<branch>-rb` when no earlier monitor commit touched that file;
  otherwise resolve by hand. Then `git branch -f monitor-rb HEAD`.
- **Prove monitor matches.** `git range-diff <tag>..<branch>-rb <tag>..monitor-rb` for
  each branch must show `=`. A `!` is fine only where two fork commits touch the same
  test file (list-worktree and list-unread do); read the diff to confirm.
- **pr/\* branches** are not on monitor. Before their PR opens (`main` in branches.txt) they go
  onto `upstream/main`. Once it is open (`pr`), leave them alone: maintainers merge `main`
  into them, and a force-push would drop that. Change them only with commits on top.
  Remove a row when its PR merges or closes.

## 4. Verify in the scratch worktree

```bash
git checkout monitor-rb
export DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null   # sandbox: no session bus
export PATH="$HOME/.nvm/versions/node/v<engines.node from package.json>/bin:$PATH"
vp i
vp run check:changed <tag>
```

If browser tests fail with "Executable doesn't exist", run
`vp exec playwright install chromium-headless-shell` in `apps/web` and rerun those
files with `vp test run <files>` there. Fix real failures in the branch's commit,
then rebuild monitor-rb.

## 5. Trial build and smoke test

```bash
node scripts/update-release-package-versions.ts "<tag without v>+monitor"
vp run --filter t3 build
git checkout -- apps/desktop/package.json apps/server/package.json apps/web/package.json packages/contracts/package.json
.agents/skills/fork-release-rebase/scripts/smoke.sh . "<tag without v>+monitor"
```

smoke.sh starts the build on a throwaway home and checks version, environment label,
`t3 auth mcp-token`, `t3 pair --base-url` and the `t3_thread_list` fields. When a fork
branch adds something a running server shows, add a check there.

## 6. Move the branches and build the release

In the main checkout:

```bash
for b in <every branch with a -rb>; do git branch -f "$b" "$b-rb"; done   # not monitor: it is checked out
git reset --keep monitor-rb
vp i
node scripts/update-release-package-versions.ts "<version>+monitor"
vp run --filter t3 build
git checkout -- apps/desktop/package.json apps/server/package.json apps/web/package.json packages/contracts/package.json
```

`vp i` and the build replace files under the running server, so do them back to back
and tell the user to restart soon. Then remove the scratch worktree
(`git worktree remove --force`) and the `-rb` branches. Keep the backups until the user
confirms the release works.

Compare the database migration smoke.sh printed with the running server's
(`curl -s http://127.0.0.1:3780/.well-known/t3/environment | jq .databaseMigration`).
If it went up, the restart migrates `~/.t3-work` one way, so the user backs it up first.

## 7. Report and hand off

Report: the release, the keep/replace/watch table with the monitor impact for any
replacement, each conflict and how you resolved it, the check and smoke results, and
anything you could not verify.

Do not push. The agent sandbox has no key for the fork. Give the user:

```bash
cd ~/projects/t3code
git push --atomic --force-with-lease origin monitor <every rebased branch>
```

and the restart, with a backup when the migration went up:

```bash
systemctl --user stop t3-work
cp -a ~/.t3-work/userdata ~/.t3-work/userdata.pre-<version>
systemctl --user start t3-work
curl -s http://127.0.0.1:3780/.well-known/t3/environment | jq .serverVersion
```

Rollback: check out `backup/pre-<tag>/monitor`, `vp i`, rebuild with the old version,
restore the `userdata` copy.
