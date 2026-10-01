---
name: git-autosync
description: Keep a workspace's GitHub copy current without thinking about it - commit and push on session start, every ~10 minutes of turns, before compact and at session end, with a secret scan in front of every commit. Use when setting up a new workspace or repo ("ponle el autosync", "que se suba solo a GitHub", "install autosync in X"), when GitHub looks behind the local copy, when a session warns "git autosync: ...", or to check whether the last push landed. Not for curated commits with real messages (do those by hand; autosync just sweeps what is left).
---

# git-autosync

Four Claude Code hooks call one script. The working tree on `main` gets committed as
`autosync: <areas> (<n> files)` and pushed in the background. It never blocks Claude:
every path exits 0, problems go to the log and, when a person has to act, to a one-line
`systemMessage`.

| Hook | Mode | Does |
|---|---|---|
| SessionStart | `start` | warns if the last push failed, fetch, fast-forward if behind, commit leftovers, push |
| Stop | `turn` | commit + push, at most once per `AUTOSYNC_THROTTLE_MIN` (default 10) minutes |
| PreCompact | `flush` | commit + push now |
| SessionEnd | `flush` | commit + push now |

## Install in a workspace

1. Copy this folder to `<repo>/.claude/skills/git-autosync/`.
2. Read the repo's `.gitignore` first. Autosync runs `git add -A`: anything not ignored gets
   committed. Check with `git add -A -n | less` and ignore media, cloud-drive shortcut files
   (`*.gdoc`, `*.gsheet`, `*.gslides`), rendered decks, temp files, nested repos.
3. Run the secret scan over what would be committed before the first sweep:
   ```bash
   P=$(grep -o "PATTERN='.*'" .claude/skills/git-autosync/git-hooks/pre-commit | sed "s/^PATTERN='//;s/'$//")
   { git diff -U0; git ls-files -o --exclude-standard -z | xargs -0 cat; } | grep -aE -- "$P"
   ```
   Empty output = clean.
4. `bash .claude/skills/git-autosync/scripts/install.sh` (idempotent). It sets
   `core.hooksPath` to `git-hooks/` unless the repo has its own (then it only checks for a
   pre-commit), adds `.claude/state/` to `.gitignore`, and wires the four hooks into
   `.claude/settings.json` without touching existing ones.
5. Hooks load on the next session. To sweep now: `bash .claude/skills/git-autosync/scripts/git-autosync.sh flush`.

## Check / fix

```bash
bash .claude/skills/git-autosync/scripts/git-autosync.sh status
```

Prints ahead/behind, dirty count, hooksPath and the last 15 log lines (`.claude/state/autosync.log`).

| Log / message | Meaning | Fix |
|---|---|---|
| `COMMIT BLOCKED by pre-commit` | secret scan hit | move the key to `.env`, or gitignore the file. False positive only: `git commit --no-verify` by hand |
| `PUSH FAILED, manual fix needed` | push rejected and the rebase conflicted | `git fetch && git rebase origin/main`, resolve, push |
| `behind N and not fast-forwardable` | main diverged | same as above |
| `.gitignore missing` | a sync client (Google Drive, Dropbox) deleted it | `git checkout -- .gitignore` |
| `skip: index.lock present` | another git command running, or a stale lock left by a sync client | if no git process runs: `rm .git/index.lock` |

## Rules

- Only `main`, only the main checkout. Worktrees and branches are left alone on purpose.
- Never commits without a `.gitignore`: sync clients have deleted it, and `.env` would go up.
- Curated commits still happen by hand when a piece of work deserves a message. Autosync
  sweeps the rest; it is a backup, not a history.
- Several sessions can share a workspace: a sweep can carry another session's half-done
  files. That is accepted. The push is what matters.
