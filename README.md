# git-autosync

A Claude Code skill that keeps your GitHub copy of a workspace up to date while you work, so you never have to remember to commit and a week of changes never lives on one laptop only.

It wires four Claude Code hooks to one shell script:

| When | What happens |
|---|---|
| Session starts | pulls if GitHub is ahead (fast-forward only), commits anything left over, pushes |
| Claude finishes a turn | commits and pushes, at most once every 10 minutes |
| Before `/compact` | commits and pushes right away |
| Session ends | commits and pushes right away |

Commits look like `autosync: journal,scripts (4 files)`. The push runs in the background, so Claude never waits on the network.

Every commit goes through a secret scan first. If the staged diff contains something shaped like an API key (Anthropic, OpenAI, GitHub, Google, Shopify, Meta, Supabase, Telegram, Trello, Perplexity, Apify, JWTs, private key blocks), or a `.env` / `.mcp.json` file, the commit is refused and the session gets a one-line warning.

## Who it is for

People who use Claude Code as a working environment rather than only for code: a folder of notes, client docs, scripts and skills that changes all day. In a folder like that, commits work as a backup, and this skill treats them as one.

If your repo is a codebase where commit history matters, you probably want your own commits. Autosync still works there, it just sweeps whatever you did not commit yourself.

## Install

```bash
cd your-workspace
git clone https://github.com/aguevara92/git-autosync .claude/skills/git-autosync
rm -rf .claude/skills/git-autosync/.git
```

Then open Claude Code in the workspace and say "install git-autosync". The skill walks Claude through it: check your `.gitignore`, run the secret scan over everything that would be committed, then run the installer. Or do it yourself:

```bash
bash .claude/skills/git-autosync/scripts/install.sh
```

The installer is safe to run twice. It:

- points `core.hooksPath` at the skill's `git-hooks/` folder (the secret scan), unless your repo already has its own hooks path
- adds `.claude/state/` to `.gitignore` (the log and the throttle timestamp live there)
- adds the four hooks to `.claude/settings.json`, leaving your existing hooks alone

Hooks load on the next session.

## Checking on it

```bash
bash .claude/skills/git-autosync/scripts/git-autosync.sh status
```

Shows commits ahead and behind, uncommitted files, the hooks path, and the last lines of `.claude/state/autosync.log`. If a background push failed, the next session start tells you.

## What it does not do

- **It only touches `main`, and only the main checkout.** Other branches and git worktrees are skipped on purpose. If you work on a branch, autosync does nothing until you are back on `main`.
- **It does not resolve conflicts.** If GitHub moved and your changes do not rebase cleanly, the push stops and the log says `PUSH FAILED`. You fix it by hand.
- **It commits everything your `.gitignore` allows.** `git add -A` is the whole design. A bad `.gitignore` means large files or private documents go to GitHub. Read yours before installing, and keep the repo private if the workspace holds anything personal.
- **The secret scan is a pattern list, not a guarantee.** It catches the common key formats. A password in plain prose, or a key format it does not know, gets through.
- **If `.gitignore` disappears, it stops.** Sync clients like Google Drive and Dropbox have deleted it in real workspaces. Without it, `.env` would be committed, so the script refuses to commit until the file is back.
- **macOS first.** It uses BSD `stat -f %m`. On Linux, change that one call to `stat -c %Y`.
- **Several sessions in the same folder share one sweep.** A commit can include another session's half-finished files. For a backup that is fine. For a clean history it is not.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `AUTOSYNC_THROTTLE_MIN` | `10` | minimum minutes between end-of-turn commits |

## License

MIT
