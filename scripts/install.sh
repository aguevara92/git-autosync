#!/bin/bash
# Wires git autosync into a workspace. Idempotent: safe to run twice.
# Usage: bash .claude/skills/git-autosync/scripts/install.sh [repo_root]
#   1. checks the repo: on main, has origin, has a .gitignore
#   2. points core.hooksPath at this skill's git-hooks/ (secret scan) unless the
#      repo already has its own hooksPath, in which case it only checks for a pre-commit
#   3. adds .claude/state/ to .gitignore
#   4. adds the four hooks to .claude/settings.json (keeps every other hook)
set -e
ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$ROOT"
SKILL_REL=".claude/skills/git-autosync"
[ -f "$SKILL_REL/scripts/git-autosync.sh" ] || { echo "FAIL: $SKILL_REL not in $ROOT. Copy the skill folder there first."; exit 1; }

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || echo "WARN: on '$branch'. Autosync only acts on main."
git remote get-url origin >/dev/null 2>&1 || { echo "FAIL: no origin remote."; exit 1; }
[ -s .gitignore ] || { echo "FAIL: no .gitignore. Write one before autosync runs git add -A."; exit 1; }

hp=$(git config core.hooksPath || true)
if [ -z "$hp" ]; then
  git config core.hooksPath "$SKILL_REL/git-hooks"
  echo "ok: core.hooksPath -> $SKILL_REL/git-hooks"
elif [ -x "$hp/pre-commit" ]; then
  echo "ok: core.hooksPath already $hp (has pre-commit, left alone)"
else
  echo "WARN: core.hooksPath is $hp with no pre-commit. Copy $SKILL_REL/git-hooks/pre-commit there."
fi

grep -qxF ".claude/state/" .gitignore || { printf '\n# hook runtime state (git-autosync log + throttle stamp)\n.claude/state/\n' >>.gitignore; echo "ok: .claude/state/ added to .gitignore"; }

mkdir -p .claude
python3 - "$SKILL_REL" <<'PY'
import json, os, sys
skill = sys.argv[1]
path = ".claude/settings.json"
d = json.load(open(path)) if os.path.exists(path) else {}
hooks = d.setdefault("hooks", {})
cmd = 'bash "${CLAUDE_PROJECT_DIR}/' + skill + '/scripts/git-autosync.sh" '
for event, mode in [("SessionStart", "start"), ("Stop", "turn"), ("PreCompact", "flush"), ("SessionEnd", "flush")]:
    groups = hooks.setdefault(event, [])
    if any("git-autosync.sh" in h.get("command", "") for g in groups for h in g.get("hooks", [])):
        print(f"ok: {event} already wired")
        continue
    groups.append({"hooks": [{"type": "command", "command": cmd + mode, "timeout": 15}]})
    print(f"ok: {event} -> {mode}")
json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
PY
echo "done. Hooks load on the next session. Check any time with: bash $SKILL_REL/scripts/git-autosync.sh status"
