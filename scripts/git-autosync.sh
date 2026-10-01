#!/bin/bash
# Keeps origin/main close to the working tree.
# Wired in .claude/settings.json by scripts/install.sh:
#   SessionStart -> "start"  fetch, fast-forward if behind, commit + push leftovers
#   Stop         -> "turn"   commit + push, throttled (AUTOSYNC_THROTTLE_MIN, default 10)
#   PreCompact   -> "flush"  commit + push now
#   SessionEnd   -> "flush"  commit + push now
# Manual: "status" prints ahead/behind, dirty count and the log tail.
# Never blocks Claude: always exits 0. Safety comes from the pre-commit secret scan
# (git-hooks/pre-commit, via core.hooksPath). Log: .claude/state/autosync.log
# Manual run: bash .claude/skills/git-autosync/scripts/git-autosync.sh flush

MODE="${1:-turn}"
[ -t 0 ] || cat >/dev/null 2>&1 # drain hook JSON on stdin

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
cd "$ROOT" 2>/dev/null || exit 0
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0

STATE="$ROOT/.claude/state"
mkdir -p "$STATE"
LOG="$STATE/autosync.log"
STAMP="$STATE/autosync.last"
THROTTLE_MIN="${AUTOSYNC_THROTTLE_MIN:-10}"

log() { echo "$(date '+%F %T') [$MODE] $*" >>"$LOG"; }
notify() { printf '{"systemMessage": "git autosync: %s"}\n' "$1"; }

if [ "$MODE" = "status" ]; then
  git fetch -q origin main 2>/dev/null
  echo "branch:  $(git rev-parse --abbrev-ref HEAD)"
  echo "ahead:   $(git rev-list --count origin/main..main 2>/dev/null)"
  echo "behind:  $(git rev-list --count main..origin/main 2>/dev/null)"
  echo "dirty:   $(git status --porcelain | wc -l | tr -d ' ') paths"
  echo "hooks:   $(git config core.hooksPath || echo 'core.hooksPath unset, NO secret scan')"
  echo "--- log"; tail -n 15 "$LOG" 2>/dev/null
  exit 0
fi

# Only the main checkout on main. Worktrees and other branches are left alone.
[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "main" ] || exit 0
[ "$(git rev-parse --git-common-dir)" = "$GIT_DIR" ] || exit 0

# Cloud sync clients (Drive, Dropbox) have deleted .gitignore before. Without it, add -A would stage .env and
# every gigabyte of media. Stop until it is back.
if [ ! -s "$ROOT/.gitignore" ]; then
  log "skip: .gitignore missing or empty"
  notify ".gitignore is missing (sync client?). Nothing committed. Restore it with: git checkout -- .gitignore"
  exit 0
fi

# Never interfere with an in-flight git operation (sync clients can also leave stale locks).
for f in index.lock MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD; do
  [ -e "$GIT_DIR/$f" ] && { log "skip: $f present"; exit 0; }
done

push_bg() {
  # Detached so the hook returns instantly.
  nohup sh -c '
    git push -q origin main >>"$1" 2>&1 && { echo "$(date "+%F %T") pushed" >>"$1"; exit 0; }
    echo "$(date "+%F %T") push rejected, trying fetch + rebase" >>"$1"
    git fetch -q origin main >>"$1" 2>&1 &&
    git rebase -q origin/main >>"$1" 2>&1 &&
    git push -q origin main >>"$1" 2>&1 &&
    { echo "$(date "+%F %T") pushed after rebase" >>"$1"; exit 0; }
    git rebase --abort >/dev/null 2>&1
    echo "$(date "+%F %T") PUSH FAILED, manual fix needed" >>"$1"
  ' _ "$LOG" >/dev/null 2>&1 &
}

commit_all() {
  [ -z "$(git status --porcelain)" ] && return 1
  git add -A >>"$LOG" 2>&1
  local files areas n
  files=$(git diff --cached --name-only)
  [ -z "$files" ] && return 1
  n=$(echo "$files" | wc -l | tr -d ' ')
  areas=$(echo "$files" | awk -F/ '{ if ($1==".claude" && NF>2) print $1"/"$2; else if (NF>1) print $1; else print "root" }' | sort -u | head -6 | paste -sd, -)
  if git commit -q -m "autosync: $areas ($n files)" >>"$LOG" 2>&1; then
    log "committed $n files: $areas"
    return 0
  fi
  # pre-commit refused (likely a secret). Unstage so nothing half-done lingers.
  git reset -q >/dev/null 2>&1
  log "COMMIT BLOCKED by pre-commit, see lines above"
  notify "commit blocked by the secret scan. Check .claude/state/autosync.log and move the key to .env or gitignore the file."
  return 2
}

case "$MODE" in
  start)
    # A push that failed in the background last session is otherwise silent.
    tail -n 1 "$LOG" 2>/dev/null | grep -q "PUSH FAILED" &&
      notify "the last push failed. Run: bash .claude/skills/git-autosync/scripts/git-autosync.sh status"
    git fetch -q origin main >>"$LOG" 2>&1 || { log "fetch failed (offline?)"; exit 0; }
    behind=$(git rev-list --count main..origin/main 2>/dev/null || echo 0)
    if [ "$behind" -gt 0 ]; then
      if git merge -q --ff-only origin/main >>"$LOG" 2>&1; then
        log "fast-forwarded $behind commits"
      else
        log "behind $behind and not fast-forwardable"
        notify "main is $behind commits behind origin and cannot fast-forward. Resolve before working."
      fi
    fi
    commit_all
    [ "$(git rev-list --count origin/main..main 2>/dev/null || echo 0)" -gt 0 ] && push_bg
    ;;
  turn|flush)
    if [ "$MODE" = "turn" ] && [ -f "$STAMP" ]; then
      age=$(( $(date +%s) - $(stat -f %m "$STAMP" 2>/dev/null || echo 0) ))
      [ "$age" -lt $(( THROTTLE_MIN * 60 )) ] && exit 0
    fi
    commit_all
    rc=$?
    [ "$rc" = 2 ] && exit 0
    touch "$STAMP"
    [ "$(git rev-list --count origin/main..main 2>/dev/null || echo 0)" -gt 0 ] && push_bg
    ;;
esac
exit 0
