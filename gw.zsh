#!/usr/bin/env zsh
# ============================================================
# gw.zsh — Nomad Git Workflow Manager
# Clean branch-first Git automation
# ============================================================

# ---------- Helpers ----------

_gw_current_branch() {
  git branch --show-current 2>/dev/null
}

_gw_on_main() {
  [[ "$(_gw_current_branch)" == "main" ]]
}

# ---------- MAIN COMMAND ----------
gw() {
  local cmd="$1"
  shift

  case "$cmd" in

    # ----------------------------------------
    # 1. sync main (safe update)
    # ----------------------------------------
    sync)
      echo "🔄 Syncing main with origin..."
      git switch main || return 1
      git pull origin main
      ;;

    # ----------------------------------------
    # 2. new branch from latest main
    # ----------------------------------------
    new)
      local name="$1"

      if [[ -z "$name" ]]; then
        echo "❌ Usage: gw new <branch-name>"
        return 1
      fi

      echo "🌿 Creating feature branch: $name"
      git switch main || return 1
      git pull origin main
      git switch -c "$name"
      ;;

    # ----------------------------------------
    # 3. status shortcut
    # ----------------------------------------
    status)
      git status -sb
      ;;

    # ----------------------------------------
    # 4. sync with latest main (rebase)
    # ----------------------------------------
    rebase)
      echo "🔀 Rebasing onto origin/main..."
      git fetch origin
      git rebase origin/main
      ;;

    # ----------------------------------------
    # 5. push current branch
    # ----------------------------------------
    push)
      local branch="$(_gw_current_branch)"
      echo "📤 Pushing $branch..."
      git push -u origin "$branch"
      ;;

    # ----------------------------------------
    # 6. cleanup merged branches
    # ----------------------------------------
    clean)
      echo "🧹 Cleaning merged branches..."

      git branch --merged main \
        | grep -v "main" \
        | xargs -r git branch -d

      echo "✅ Local merged branches removed"
      ;;

    # ----------------------------------------
    # 7. full overview
    # ----------------------------------------
    tree)
      git log --oneline --graph --decorate --all --max-count=30
      ;;

    # ----------------------------------------
    # 8. help
    # ----------------------------------------
    *)
      cat <<EOF
gw — Git Workflow Manager

Commands:
  gw sync        → update main from origin
  gw new <name>  → create feature branch from latest main
  gw status      → git status (short)
  gw rebase      → rebase current branch onto origin/main
  gw push        → push current branch
  gw clean       → delete merged local branches
  gw tree        → show commit graph
EOF
      ;;
  esac
}