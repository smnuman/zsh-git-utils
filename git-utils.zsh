#!/usr/bin/env zsh
# ~/.config/zsh/git-utils/git-utils.zsh
# ---
GIT_UTILS_DEBUG="${GIT_UTILS_DEBUG:-false}"    # git-utils internal debug messages

# Weekly cleanup for git-utils logs (keeps 1 week of history)
git_utils_log_cleanup() {
    local log_file="$ZLOGDIR/git-utils.zlog"
    local timestamp_file="$ZLOGDIR/.git-utils-cleanup-timestamp"
    local current_time=$(date +%s)
    local cleanup_interval=604800  # 1 week in seconds

    # Check if it's time for cleanup
    if [[ -f "$timestamp_file" ]]; then
        local last_cleanup=$(cat "$timestamp_file" 2>/dev/null || echo 0)
        [[ $((current_time - last_cleanup)) -lt $cleanup_interval ]] && return 0
    fi

    # Perform cleanup if log exists and is over 1MB
    if [[ -f "$log_file" && $(stat -f%z "$log_file" 2>/dev/null || wc -c < "$log_file") -gt 1048576 ]]; then
        # Keep only last 500 lines (roughly 1 week of activity)
        tail -n 500 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
        echo "# Log cleaned on $(date) - keeping last 500 lines" >> "$log_file"
    fi

    # Update cleanup timestamp
    echo "$current_time" > "$timestamp_file"
}

# Run cleanup check (non-blocking)
git_utils_log_cleanup

# =============================================================================
# 🔧 CORE HELPER FUNCTIONS - Provider-agnostic utilities
# =============================================================================
# Internal utility e.g.: _gituser → returns active git username

local SAVELOGFILE=""

__glog_scope_start() {
    SAVELOGFILE="$LOGFILE"
    export LOGFILE="git-utils.zlog"

    local caller="${1:-${funcstack[2]:-main}}"
    zshlog --info -v=$GIT_UTILS_DEBUG "${caller}: ↳ Logging Initiated: $(date '+%Y%m%d-%H:%M:%S')"
}
__glog_scope_end() {
    local caller="${1:-${funcstack[2]:-main}}"
    zshlog --info -v=$GIT_UTILS_DEBUG "${caller}: ↩ Concluded Logging at $(date '+%Y%m%d-%H:%M:%S')"

    LOGFILE="$SAVELOGFILE"
    SAVELOGFILE=""
}

# Toggle SSH origin github.com ↔ gitlab.com
git-toggle-remote() {
    if [[ ! -d .git ]]; then
        echo -e "\033[1;31mnot a git repo\033[0m" >&2
        return 1
    fi

    local url=${$(git remote get-url origin 2>/dev/null):-}
    [[ -z $url ]] && {
        echo -e "\033[1;31mno origin remote\033[0m" >&2
        return 1
    }
    [[ $url != git@* ]] && {
        echo -e "\033[1;33mwarning: only ssh supported\033[0m" >&2
        return 1
    }

    local reset=$'\e[0m'
    local yellow=$'\e[1;33m'
    local green=$'\e[1;32m'
    local cyan=$'\e[1;36m'

    if [[ $url == *github.com* ]]; then
        git remote set-url origin "${url/github.com/gitlab.com}"
        echo -e "  ${yellow}→${reset} switching to ${cyan}GitLab${reset}"
    elif [[ $url == *gitlab.com* ]]; then
        git remote set-url origin "${url/gitlab.com/github.com}"
        echo -e "  ${yellow}→${reset} switching to ${green}GitHub${reset}"
    else
        echo -e "\033[1;31mhost not github.com or gitlab.com\033[0m" >&2
        return 1
    fi

    echo
    git remote -v | command grep '^origin' | sed "s/^origin\s\+/${yellow}origin${reset}  /"
}

# git-aliases() {
#   git config --get-regexp '^alias\.' |
#   awk '{sub(/^alias\./,""); printf "%-16s = %s\n", $1, substr($0, index($0," ")+1)}'
# }

git-aliases() {
  git config --get-regexp '^alias\.' 2>/dev/null |
  sed -E 's/^alias\.([^ ]+)[ ]+(.*)$/\1\t\2/' |
  while IFS=$'\t' read -r key val; do
    [[ -z "$key" ]] && continue
    if [[ -n "$val" ]]; then
      print -P "%F{cyan}${key}%-18s%f %F{244}=%f %F{green}${val}%f" ""
    else
      print -P "%F{cyan}${key}%f"
    fi
  done
}

[[ -f "$GUTILS/git-ai-remotes" ]] && source "${GUTILS}/git-ai-remotes" || zshlog --error -v=$GIT_UTILS_DEBUG "Failed to load git-ai-remotes"

# 🏷️  Generate standardized repository name from directory or custom input
# Usage: _grepo_name [dir] [custom_name]
_grepo_name() {

    local dir="${1:-$PWD}" custom="$2"

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    # Return validated custom name if provided
    [[ -n "$custom" ]] && { [[ "$custom" =~ ^[a-zA-Z0-9_-]+$ && ${#custom} -le 40 ]] && { echo "$custom"; return 0; } || { zshlog --error -v=$GIT_UTILS_DEBUG "Invalid repo name: $custom (alphanumeric/hyphens, max 40 chars)"; return 1; }; }

    # Generate from directory: parent-child format
    local base="${dir:t}"           # Get basename (tail)
    local parent="${dir:h:t}"       # Get parent directory name
    base="${base#.}"                # Strip leading dot if present
    parent="${parent#.}"            # Strip leading dot if present
    local name="${parent}-${base}"

    [[ -z "$base" || -z "$parent" ]] && { zshlog --error -v=$GIT_UTILS_DEBUG "Failed to generate repo name from: $dir"; return 1; }

    [[ "$name" == "-" || ${#name} -gt 40 ]] && { zshlog --error -v=$GIT_UTILS_DEBUG "Invalid generated name: $name"; return 1; }

    echo "$name"
}

# 🌐 Get Git provider (github/gitlab) from GIT_PROVIDER env var
# Usage: _githost
_githost() {

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    local provider="${GIT_PROVIDER:-github}"
    provider="${provider:l}"
    case "$provider" in
        github|gitlab) echo "$provider" ;;
        *) zshlog --warn -v=$GIT_UTILS_DEBUG "Unknown GIT_PROVIDER: $provider, using github"; echo "github" ;;
    esac

}

# 🔗 Generate SSH remote URL for provider
# Usage: _gurl <username> <repo_name> [provider]
_gurl() {

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    local user="$1" repo="$2" provider="${3:-$(_githost)}"
    [[ -z "$user" || -z "$repo" ]] && { zshlog --error -v=$GIT_UTILS_DEBUG "_gurl requires [username] and [repo_name]"; return 1; }
    case "$provider" in
        github) echo "git@github.com:${user}/${repo}.git" ;;
        gitlab) echo "git@gitlab.com:${user}/${repo}.git" ;;
             *) zshlog --error -v=$GIT_UTILS_DEBUG "Unsupported provider: $provider"; return 1 ;;
    esac

}

# 🛠️  Get CLI command for provider (gh/glab)
# Usage: _gitcli <command> [provider]
_gitcli() {

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    local cmd="$1" provider="${2:-$(_githost)}"
    case "$provider" in
        github) echo "gh $cmd" ;;
        gitlab) echo "glab $cmd" ;;
             *) zshlog --error -v=$GIT_UTILS_DEBUG "Unsupported provider: $provider"; return 1 ;;
    esac

}

# 👤 Get username from GITHUB_USER/GITLAB_USER env var
# Usage: _gituser [provider]
_gituser() {

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    local provider="${1:-$(_githost)}"
    case "$provider" in
        github)
            [[ -n "$GITHUB_USER" ]] && { echo "$GITHUB_USER"; return 0; }
            zshlog --error -v=$GIT_UTILS_DEBUG "GITHUB_USER not set" && return 1
            ;;
        gitlab)
            [[ -n "$GITLAB_USER" ]] && { echo "$GITLAB_USER"; return 0; }
            [[ -n "$GITHUB_USER" ]] && { zshlog --warn -v=$GIT_UTILS_DEBUG "GITLAB_USER not set, using GITHUB_USER"; echo "$GITHUB_USER"; return 0; }
            zshlog --error -v=$GIT_UTILS_DEBUG "GITLAB_USER not set" && return 1
            ;;
        *) zshlog --error -v=$GIT_UTILS_DEBUG "Unsupported provider: $provider"; return 1 ;;
    esac

}

# =============================================================================
# 🔐 ENCRYPTION FUNCTIONS - git-crypt integration
# =============================================================================

# 🔐 Detect if directory contains sensitive files
_gsensitive() {

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    local dir="${1:-$PWD}"
    local sensitive_patterns=(
        "*.env"
        ".env"
        ".env.*"
        "*.key"
        "*.pem"
        "*.p12"
        "*.pfx"
        "*secret*"
        "*credential*"
        "*password*"
        "*.token"
        ".ssh/id_*"
        ".ssh/*_rsa"
        ".gnupg/*.key"
    )

    # Enable NULL_GLOB and GLOB_DOTS to match hidden files
    setopt local_options null_glob glob_dots

    zshlog --info -v=$GIT_UTILS_DEBUG "🔍 Checking for sensitive files in ${(q)dir/#$HOME/~}..."

    for pattern in "${sensitive_patterns[@]}"; do
        # Use array expansion to check for matches
        local matches=("$dir"/$~pattern)
        if [[ ${#matches[@]} -gt 0 && -e "${matches[1]}" ]]; then
            return 0  # Found sensitive files
        fi
    done
    return 1  # No sensitive files found

}

# 🔐 Add files/folders to .gitcrypt manifest
gitcrypt() {
    [[ "$1" == (-h|--help) || -z "$1" ]] && {
        echo "\n🔐 Usage: gitcrypt [-f] <path1> [path2 ...]"
        echo "Adds files or folders to the .gitcrypt manifest for encryption."
        echo "  -f    Treat each argument as a folder (adds /** recursively)"
        echo "\nExample:"
        echo "  gitcrypt secrets.env keys.pem"
        echo "  gitcrypt -f nomad vault\n"
        return 0
    }

    local folder_mode=false;  [[ "$1" == "-f" ]] && { folder_mode=true; shift; }

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    [[ $# -eq 0 ]] && { zshlog --error -v=$GIT_UTILS_DEBUG "No paths given"; return 1; }
    [[ ! -f .gitcrypt ]] && touch .gitcrypt

    if [[ "$folder_mode" == true ]]; then
        for item in "$@"; do
            local pattern="**/${(q)item}/**"
            echo "$pattern" >> .gitcrypt
            zshlog --info -v=$GIT_UTILS_DEBUG "Added folder pattern '$pattern' to .gitcrypt"
        done
    else
        for item in "$@"; do
            local pattern="${(q)item}"
            echo "$pattern" >> .gitcrypt
            zshlog --info -v=$GIT_UTILS_DEBUG "Added file '$pattern' to .gitcrypt"
        done
    fi

    echo "" >> .gitcrypt
    sort -u .gitcrypt -o .gitcrypt
    zshlog --info -v=$GIT_UTILS_DEBUG "✅ .gitcrypt updated (deduplicated)" ; cat .gitcrypt

}

# 🔐 git-crypt setup (smart + force-capable + concise)
# Usage: gencrypt_setup [dir=. ] [auto=true] [force=false]
gencrypt_setup() {
    [[ "$1" == (-h|--help) || -z "$1" ]] && {
        echo "\n🔐  Usage: gencrypt_setup [dir=. ] [auto=true] [force=false]\n"
        echo "Examples:"
        echo "  gencrypt_setup .             # Auto-detect sensitive files & setup git-crypt"
        echo "  gencrypt_setup . false       # Skip detection, setup encryption anyway"
        echo "  gencrypt_setup . true true   # Force full reinitialisation"
        echo "\nNotes:"
        echo "  - Works inside Git repos only"
        echo "  - Backs up .gitattributes before modifying"
        echo "  - Loads extra patterns from .gitcrypt (if exists)"
        echo "  - Installs pre-commit secret scan hook automatically"
        return 0
    }

    local dir="${1:-$PWD}" auto="${2:-true}" force="${3:-false}"
    (
        cd "$dir" || return 1

        __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

        # Check if in git repo and git-crypt installed
        git rev-parse --is-inside-work-tree &>/dev/null || { zshlog --error -v=$GIT_UTILS_DEBUG "Not a git repo or not in one: ${dir/#$HOME/~}"; return 1; }
        command -v git-crypt &>/dev/null || { zshlog --warn -v=$GIT_UTILS_DEBUG "git-crypt not installed. Run: brew install git-crypt"; return 1; }

        # 💣 Force re-init mode
        if [[ "$force" == "true" ]]; then
            zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  Force mode enabled — removing existing git-crypt data"
            rm -rf .git/git-crypt .gitattributes.backup 2>/dev/null
            git rm --cached .gitattributes 2>/dev/null || true
            git-crypt init && zshlog --info -v=$GIT_UTILS_DEBUG "✅ git-crypt reinitialised (force)" || { zshlog --error -v=$GIT_UTILS_DEBUG "Failed to reinitialise"; return 1; }
        else
            # Normal mode: skip if already initialized otherwise initialize if not fails
            git-crypt status &>/dev/null && zshlog --info -v=$GIT_UTILS_DEBUG "Detected git-crypt setup, skipping init" || {
                git-crypt init && zshlog --info -v=$GIT_UTILS_DEBUG "✅ git-crypt initialised" || {
                    zshlog --error -v=$GIT_UTILS_DEBUG "Failed to init"; return 1;
                };
            }
        fi

        [[ "$auto" == "true" ]] && { _gsensitive "$dir" && zshlog --info -v=$GIT_UTILS_DEBUG "Sensitive files found, updating patterns..." || zshlog --info -v=$GIT_UTILS_DEBUG "No sensitive files found, updating anyway."; }

        # Default patterns
        local default_patterns=(
            "**/*.env"
            "**/*.key"
            "**/*.pem"
            "**/*.p12"
            "**/*.pfx"
            "**/*secret*"
            "**/*credential*"
            "**/*password*"
            "**/*.token"
            "**/.ssh/id_*"
            "**/.ssh/*_rsa"
            "**/.gnupg/*.key"
            "**/secrets/"
            "**/credentials/"
        )

        # Load custom patterns from .gitcrypt
        local custom_patterns=()
        [[ -f .gitcrypt ]] && while IFS= read -r line; do
            line="${line%%\#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"   # previously done!
            [[ -n "$line" ]] && custom_patterns+=("$line")
        done < .gitcrypt

        local all_patterns=("${default_patterns[@]}" "${custom_patterns[@]}")

        # Backup or create .gitattributes
        [[ -f .gitattributes ]] && { cp .gitattributes .gitattributes.backup && zshlog --info -v=$GIT_UTILS_DEBUG "Backed up existing .gitattributes"; } || { echo "# git-crypt encryption patterns" > .gitattributes && zshlog --info -v=$GIT_UTILS_DEBUG "Created .gitattributes"; }

        # Add missing patterns
        local added=0; for p in "${all_patterns[@]}"; do grep -qxF "$p filter=git-crypt diff=git-crypt" .gitattributes || { echo "$p filter=git-crypt diff=git-crypt" >> .gitattributes; ((added++)); }; done
        zshlog --info -v=$GIT_UTILS_DEBUG "✅ Added $added patterns to .gitattributes"

        # Stage .gitattributes for commit
        git add .gitattributes && zshlog --info -v=$GIT_UTILS_DEBUG "Staged .gitattributes"

        # Attempt pre-commit hook installation
        gshook "$dir" 2>/dev/null || zshlog --warn -v=$GIT_UTILS_DEBUG "Skipped hook install"

        zshlog --info -v=$GIT_UTILS_DEBUG "✅ git-crypt setup complete${force:+ (forced)}"

    )
}

# 🔐 Check if a file would be encrypted
gencrypt_check() {
    [[ "$1" == (-h|--help) || -z "$1" ]] && {
        echo "\n🧩 Usage: gencrypt_check <file>\n"
        echo "Checks whether a file is encrypted under git-crypt."
        echo "Example:  gencrypt_check secrets.env\n"
        return 0
    }
    local file="$1"

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    ! command -v git-crypt &>/dev/null && { zshlog --error -v=$GIT_UTILS_DEBUG "git-crypt not installed"; return 1; }
    [[ ! -f .git/git-crypt/keys/default ]] && { zshlog --error -v=$GIT_UTILS_DEBUG "git-crypt not initialised in this repo"; return 1; }
    git-crypt status "$file" &>/dev/null && zshlog --info -v=$GIT_UTILS_DEBUG "File: $file - Encrypted ✓" || { zshlog --warn -v=$GIT_UTILS_DEBUG "File: $file - Not encrypted"; return 1; }

}

# 🔐 Scan for potential secrets in unencrypted files
gsecrets() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n🔍 Usage: gsecrets [dir=.]\n"
        echo "Scans repository for potential secrets or credentials.\n"
        echo "Examples:"
        echo "  gsecrets .             # Scan current repo"
        echo "  gsecrets ~/project     # Scan specific path\n"
        return 0
    }

    local dir="${1:-$PWD}"

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    zshlog --info -v=$GIT_UTILS_DEBUG "🔍 Scanning for potential secrets in ${dir/#$HOME/~}..."

    local secret_patterns=(
        "password.*=.*"
        "api[_-]?key.*=.*"
        "secret.*=.*"
        "token.*=.*"
        "private[_-]?key"
        "-----BEGIN.*PRIVATE KEY-----"
        "AKIA[0-9A-Z]{16}"  # AWS keys
        "ghp_[0-9a-zA-Z]{36}"  # GitHub tokens
    )

    local found=0
    for pattern in "${secret_patterns[@]}"; do
        while IFS= read -r match; do
            found=1
            echo "⚠️  Potential secret found: $match"
            zshlog --warn -v=$GIT_UTILS_DEBUG "Potential secret detected: $match"
        done < <(git grep -i -n -E "$pattern" 2>/dev/null | head -20)
    done

    [[ $found -eq 0 ]] && zshlog --info -v=$GIT_UTILS_DEBUG "✅ No obvious secrets detected" || { echo ""; zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  Review these files and ensure sensitive data is encrypted!"; }

    return $found

}

# 🔐 Install pre-commit hook for secret scanning
#
# Purpose:      gshook sets up a pre-commit hook that scans staged files for potential secrets using regex patterns.
#               It integrates with git-crypt by warning about unencrypted sensitive files and blocks commits if potential secrets are detected,
#               encouraging secure handling of sensitive data.
#
# Operates on:  the current git repository, modifying .git/hooks/pre-commit.
#               It checks for existing hooks to avoid overwriting and appends if necessary.
#               The hook scans for patterns like passwords, API keys, tokens, and private keys in staged files before allowing commits.
#
# works on:     git repositories, modifies .git/hooks/pre-commit, checks staged files for secrets,
#               integrates with git-crypt patterns, and provides warnings and commit blocking for potential secrets.
#
# Usage: gshook [dir=.]
# Example: gshook .
gshook() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n🪝 Usage: gshook [dir=.]\n"
        echo "Installs a pre-commit hook for secret scanning."
        echo "Example:  gshook ~/.config/nomad\n"
        return 0
    }

    local dir="${1:-$PWD}"

    (
        cd "$dir" || return 1

        [[ ! -d .git ]] && { zshlog --error -v=$GIT_UTILS_DEBUG "Not a git repository: ${dir/#$HOME/~}"; return 1; }

        local hook_file=".git/hooks/pre-commit"

        __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

        # Check if hook already exists
        if [[ -f "$hook_file" ]]; then
            if grep -q "Secret scanning via git-crypt" "$hook_file" 2>/dev/null; then
                zshlog --info -v=$GIT_UTILS_DEBUG "Secret scanning hook already installed"
                return 0
            fi
            # If other hook exists, append silently (non-destructive)
            zshlog --info -v=$GIT_UTILS_DEBUG "Appending secret scanning to existing pre-commit hook"
        fi

        zshlog --info -v=$GIT_UTILS_DEBUG "Installing pre-commit secret scanning hook..."

        # Create or append to hook
        cat >> "$hook_file" <<'HOOK_EOF'

# ============================================================================
# Secret scanning via git-crypt integration
# ============================================================================
echo "🔍 Scanning for secrets..."

# Secret patterns (consistent with gsecrets function)
SECRET_PATTERNS=(
    "password.*="
    "api[_-]?key.*="
    "secret.*="
    "token.*="
    "private[_-]?key"
    "-----BEGIN.*PRIVATE KEY-----"
    "AKIA[0-9A-Z]{16}"        # AWS access keys
    "ghp_[0-9a-zA-Z]{36}"     # GitHub personal access tokens
)

secrets_found=0

# Get list of staged files
staged_files=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)

if [[ -n "$staged_files" ]]; then
    for pattern in "${SECRET_PATTERNS[@]}"; do
        # Check each staged file for the pattern
        while IFS= read -r file; do
            if [[ -f "$file" ]] && git diff --cached "$file" | grep -i -E "$pattern" >/dev/null 2>&1; then
                secrets_found=1
                echo "$file"
                echo "⚠️  WARNING: Potential secret detected matching pattern: $pattern"
            fi
        done <<< "$staged_files"
    done
fi

if [[ $secrets_found -eq 1 ]]; then
    echo ""
    echo "❌ Commit blocked: Potential secrets detected!"
    echo "   Please review the files above and ensure sensitive data is:"
    echo "   1. Encrypted with git-crypt (.gitattributes)"
    echo "   2. Added to .gitignore"
    echo "   3. Not actually sensitive (false positive)"
    echo ""
    echo "To bypass this check (not recommended): git commit --no-verify"
    exit 1
fi

echo "✅ No secrets detected"
# ============================================================================
HOOK_EOF

        chmod +x "$hook_file"
        zshlog --info -v=$GIT_UTILS_DEBUG "✅ Secret scanning pre-commit hook installed"
        zshlog --info -v=$GIT_UTILS_DEBUG "Hook will scan for secrets before each commit"
        zshlog --info -v=$GIT_UTILS_DEBUG "To bypass: git commit --no-verify (not recommended)"

    )
}

# 🧩 Utility: Isolate a directory as a git repo with .gitignore to prevent parent→child contamination
_gisolate() {
    local dir="${1:-$PWD}"
    (
        __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

        zshlog --info -v=$GIT_UTILS_DEBUG "Entering git repo locally for isolating: ${(q)dir}"
        cd "$dir" || { zshlog --error -v=$GIT_UTILS_DEBUG "❌  Directory not found or in-accessible!"; return 1;}

        if ! git rev-parse --is-inside-work-tree &>/dev/null; then
            zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  Initializing isolated git repo in $dir..."
            git init || return 1
            git branch -M main || return 1
        fi

        local changed=0
        [[ ! -f .gitignore ]] && {
            zshlog --info -v=$GIT_UTILS_DEBUG "Creating .gitignore to isolate repo ${(q)dir}"
            echo "*" > .gitignore;
            echo "!.gitignore" >> .gitignore; changed=1;
        } || {
            zshlog --info -v=$GIT_UTILS_DEBUG "Updating existing .gitignore to isolate repo ${(q)dir}"
            grep -qxF "*" .gitignore || { echo "*" >> .gitignore; changed=1; };
            grep -qxF "!.gitignore" .gitignore || { echo "!.gitignore" >> .gitignore; changed=1; };
        }

        [[ $changed -eq 1 ]] && {
            git add .gitignore;
            git commit -m "Update .gitignore to isolate repo";
            zshlog --info -v=$GIT_UTILS_DEBUG "✅ .gitignore updated to isolate repo";
        }

    )
}

# 🧩 Update a submodule (e.g. ~/.config/zsh & ~/.config/zsh/prompt)
_gsubmod() {
  local msg="$1"
  local dir="${2:-$PWD}"

  [[ -z "$msg" ]] && { echo "Usage: _gsubmod <commit-message> [dir]"; return 1; }

  (
    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    cd "$dir" || { zshlog --error -v=$GIT_UTILS_DEBUG "❌  Directory not found or in-accessible!" ; return 1; }
    ! git rev-parse --is-inside-work-tree &>/dev/null && { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Not a git repo: ${dir/#$HOME/~}"; return 1; }

    # Try to add files (non-fatal if fails - might already be staged)
    git add . 2>/dev/null && zshlog --info -v=$GIT_UTILS_DEBUG "Files added." || zshlog --info -v=$GIT_UTILS_DEBUG "Files already staged or nothing new to add."

    # Check if there are any changes to commit (staged, unstaged, or untracked)
    local has_staged="$(git diff --cached --name-only)"
    local has_unstaged="$(git diff HEAD --name-only 2>/dev/null)"
    local has_untracked="$(git ls-files --others --exclude-standard)"

    if [[ -n "$has_staged" ]] || [[ -n "$has_unstaged" ]] || [[ -n "$has_untracked" ]]; then
        if ! git commit -m "$msg"; then
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to commit."
            return 1
        fi
        zshlog --info -v=$GIT_UTILS_DEBUG "Commit: $msg"

        # Check for dirty submodules before pushing
        if git submodule status 2>/dev/null | grep -q '^[+]'; then
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Cannot push: submodules have uncommitted changes"
            zshlog --info -v=$GIT_UTILS_DEBUG "💡 Fix: cd into each submodule and run '_gsubmod <msg>'"
            zshlog --info -v=$GIT_UTILS_DEBUG "Dirty submodules:"
            git submodule status | grep '^[+]' | awk '{print "   - " $2}'
            return 1
        fi

        if ! git push; then
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to push."
            return 1
        fi
        zshlog --info -v=$GIT_UTILS_DEBUG "✅ Submodule updated in ${dir/#$HOME/~}"
    elif git rev-parse HEAD >/dev/null 2>&1; then
        zshlog --info -v=$GIT_UTILS_DEBUG "No changes to commit. Attempting to push existing commits..."
        git push || zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  No changes to push in: ${dir/#$HOME/~}"
    else
        zshlog --info -v=$GIT_UTILS_DEBUG "✅ Submodule already complete. Nothing further to do."
        return 0
    fi

  )
}

# 🧩 Update parent repo to commit submodule pointer (e.g. ~/.config)
_gparent() {
  local msg="$1"
  local dir="${2:-$PWD}"

  [[ -z "$msg" ]] && { echo "Usage: _gparent <commit-message> [dir]"; return 1; }

  (
    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    cd "$dir" || { zshlog --error -v=$GIT_UTILS_DEBUG "❌  Directory not found or in-accessible!" ; return 1; }
    ! git rev-parse --is-inside-work-tree &>/dev/null && { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Not a git repo: ${dir/#$HOME/~}"; return 1; }

    # Try to add files (non-fatal if fails - might already be staged)
    git add . 2>/dev/null && zshlog --info -v=$GIT_UTILS_DEBUG "Submodule pointers added." || zshlog --info -v=$GIT_UTILS_DEBUG "Submodule pointers already staged or nothing new to add."

    # Check if there are any changes to commit (staged, unstaged, or untracked)
    local has_staged="$(git diff --cached --name-only)"
    local has_unstaged="$(git diff HEAD --name-only 2>/dev/null)"
    local has_untracked="$(git ls-files --others --exclude-standard)"

    if [[ -n "$has_staged" ]] || [[ -n "$has_unstaged" ]] || [[ -n "$has_untracked" ]]; then
        if ! git commit -m "$msg"; then
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to commit."
            return 1
        fi
        zshlog --info -v=$GIT_UTILS_DEBUG "Commit: $msg"

        # Check for dirty submodules before pushing
        if git submodule status 2>/dev/null | grep -q '^[+]'; then
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Cannot push: submodules have uncommitted changes"
            zshlog --info -v=$GIT_UTILS_DEBUG "💡 Fix: cd into each submodule and run '_gsubmod <msg>'"
            zshlog --info -v=$GIT_UTILS_DEBUG "Dirty submodules:"
            git submodule status | grep '^[+]' | awk '{print "   - " $2}'
            return 1
        fi

        if ! git push; then
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to push."
            return 1
        fi
        zshlog --info -v=$GIT_UTILS_DEBUG "✅ Parent repo updated with submodule pointers in ${dir/#$HOME/~}"
    elif git rev-parse HEAD >/dev/null 2>&1; then
        zshlog --info -v=$GIT_UTILS_DEBUG "No changes to submodule pointers. Attempting to push existing commits..."
        git push || zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  No changes to push in: ${dir/#$HOME/~}"
    else
        zshlog --info -v=$GIT_UTILS_DEBUG "✅ Parent repo already complete. Nothing further to do."
        return 0
    fi

  )
}

# Push to all configured remotes
git-push-all() {
    local branch="$$   {1:-   $$(git rev-parse --abbrev-ref HEAD)}"
    local remotes=($$   (git remote | grep -E '^(origin|github|gitlab|bitbucket)   $$'))

    [[ ${#remotes[@]} -eq 0 ]] && { echo "No known remotes found."; return 1; }

    for remote in "${remotes[@]}"; do
        print -P "%F{cyan}→ Pushing to $$   {remote}/   $${branch}%f"
        git push "$$   {remote}" "   $${branch}" || {
            print -P "%F{yellow}Push to ${remote} failed – skipping%f"
        }
    done

    print -P "%F{green}Push to all remotes completed.%f"
}

# Optional: alias
# alias gpa='git-push-all'

# ---
# Purpose: Main function to initialize and push a local directory to a new Git repository on GitHub/GitLab, with optional encryption setup.
# Usage: grepo [commit_msg] [optional_path]
# Example: grepo "Initial commit" "repo-stuff/my-new-repo/"

grepo() (
    local usage="\n\t❗ Usage: grepo [ [-h|--help] | [commit_msg] [repo_name] ]\n"
    [[ "$1" == (-h|--help|-help|/\?) ]] && { echo "$usage"; return 0; }
    [[ $# -gt 2 ]] && { echo "$usage"; return 1; }

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    # Generate repo name and get provider info using helper functions
    local commit_msg="${1:-Initial commit}" dir="$PWD"
    local repo_name=$(_grepo_name "$dir" "$2") || return 1
    local provider=$(_githost)
    local user=$(_gituser "$provider") || return 1
    local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")

    # User validation
    echo "ℹ️  Running: grepo <$repo_name> \"$commit_msg\" → ${dir/#$HOME/~} [$provider]"
    read -r "?❓ Proceed? [y/N] " reply
    [[ ! "$reply" =~ ^[Yy]$ ]] && { zshlog --warn -v=$GIT_UTILS_DEBUG "🚫 Aborted by user"; return 1; }

    echo "📦 Repository: $user/$repo_name"
    read -r "?❓ Proceed? [y/N] " reply
    [[ ! "$reply" =~ ^[Yy]$ ]] && { zshlog --warn -v=$GIT_UTILS_DEBUG "🚫 Repo name rejected"; return 1; }

    # Initialize git repo if needed
    git rev-parse --is-inside-work-tree &>/dev/null || {
        zshlog --info -v=$GIT_UTILS_DEBUG "⚠️  Initializing git repo in ${dir/#$HOME/~}..."; git init &&
        zshlog --info -v=$GIT_UTILS_DEBUG "✅  Git repo initialized." &&
        git branch -M main || {
            zshlog --error -v=$GIT_UTILS_DEBUG "❌  Failed to initialize git repo."; return 1;
        };
    }

    # Auto-setup encryption if sensitive files detected
    gencrypt_setup "$dir" true || {
        zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  Encryption setup failed or skipped ⁉️ "
    }

    # Check and set remote using helper function
    local remote_url=$(_gurl "$user" "$repo_name" "$provider") || return 1
    git remote get-url origin &>/dev/null && { local current_remote=$(git remote get-url origin); [[ "$current_remote" != "$remote_url" ]] && { git remote set-url origin "$remote_url" || { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to update remote"; return 1; }; }; zshlog --info -v=$GIT_UTILS_DEBUG "⚠️  Remote 'origin' → $current_remote"; } || { git remote add origin "$remote_url" || { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to set remote"; return 1; }; zshlog --info -v=$GIT_UTILS_DEBUG "✅ Remote 'origin' → $remote_url"; }

    # Prevent parent → child repo contamination
    _gisolate "$dir"

    # Add and commit files
    zshlog --info -v=$GIT_UTILS_DEBUG "💫 Adding files from ${dir/#$HOME/~} to $repo_name.git..."

    # Try to add files (non-fatal if fails - might already be staged)
    git add . 2>/dev/null && zshlog --info -v=$GIT_UTILS_DEBUG "Files added." || zshlog --info -v=$GIT_UTILS_DEBUG "Files already staged or nothing new to add."

    # Check if there are any changes to commit (staged, unstaged, or untracked)
    local has_staged="$(git diff --cached --name-only)"
    local has_unstaged="$(git diff HEAD --name-only 2>/dev/null)"
    local has_untracked="$(git ls-files --others --exclude-standard)"

    if [[ -n "$has_staged" ]] || [[ -n "$has_unstaged" ]] || [[ -n "$has_untracked" ]]; then
        if ! git commit -m "$commit_msg"; then
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to commit."
            return 1
        fi
        zshlog --info -v=$GIT_UTILS_DEBUG "Commit: $commit_msg"
    elif git rev-parse HEAD >/dev/null 2>&1; then
        zshlog --info -v=$GIT_UTILS_DEBUG "No changes to commit. Proceeding with existing commits..."
    else
        zshlog --info -v=$GIT_UTILS_DEBUG "✅ Local repo already complete. Nothing further to do."
        return 0
    fi

    # Ensure branch is up-to-date before pushing
    if git ls-remote --exit-code origin "$current_branch" &>/dev/null; then
        zshlog --info -v=$GIT_UTILS_DEBUG "🔄 Syncing with remote ($current_branch)..."

        if ! git fetch origin "$current_branch"; then
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to fetch remote branch"
            return 1
        fi

        # Refuse dirty rebase environments
        if [[ -n "$(git status --porcelain)" ]]; then
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Working tree not clean. Commit or stash first."
            return 1
        fi

        # If local is behind, rebase
        if ! git merge-base --is-ancestor "origin/$current_branch" HEAD; then
            if ! git rebase "origin/$current_branch"; then
                zshlog --error -v=$GIT_UTILS_DEBUG "❌ Rebase failed. Resolve manually."
                return 1
            fi
            zshlog --info -v=$GIT_UTILS_DEBUG "✅ Rebased onto remote"
        fi
    fi

    # Push to remote
    git push -u origin "$current_branch" || {
        zshlog --warn -v=$GIT_UTILS_DEBUG "⁉️  Push failed for '$user/$repo_name'. Checking remote repo..."
        local cli_check=$(_gitcli "repo view $user/$repo_name" "$provider") || return 1
        local cli_create=$(_gitcli "repo create $user/$repo_name --public" "$provider") || return 1

        eval "$cli_check" &>/dev/null || {
            zshlog --info -v=$GIT_UTILS_DEBUG "📡 Creating repo $user/$repo_name on $provider..."
            eval "$cli_create" && {
                zshlog --info -v=$GIT_UTILS_DEBUG "✅ Repo created"
                git push -u origin "$current_branch" || { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Push failed after repo creation"; return 1; }
            } || { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to create repo"; return 1; }
        } || { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Push failed for unknown reasons"; return 1; }
    }

    zshlog --info -v=$GIT_UTILS_DEBUG "✅ Successfully pushed to $user/$repo_name"

    # Update parent repo if it's a git repo
    parent_dir=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$parent_dir" && -d "$parent_dir/.git" ]]; then
        (cd "$parent_dir" && _gparent "Update submodule pointer: $repo_name")
    else
        zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  Skipping parent module update — not in a Git repo."
    fi

)

# 🧩 Git utility for submodules
# Purpose: Initialize and push a local directory as a new Git repository, then update the parent repository to point to it as a submodule.
# Usage: gsub <folder> [commit_msg] [repo_name]
# Example: gsub "repo-stuff/my-new-repo/" "Adding submodule - repo-stuff/my-new-repo/"

gsub() (
    local usage="\n\t⚠️  Usage: gsub <subdirectory> [<commit_msg> = 'Adding' [<repo_name>]]\n"
    [[ "$1" == (-h|--help|-help|/\?) ]] && { echo "$usage"; return 0; }

    local subdir="$1" commit_msg="${2:-Adding}" custom_repo="$3"
    [[ -z "$subdir" ]] && { echo "$usage"; return 1; }

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    # Get provider info
    local provider=$(_githost)
    local user=$(_gituser "$provider") || { zshlog --error -v=$GIT_UTILS_DEBUG "❌  User ${(q)user}\@${(q)provider} not found!" ; return 1; }

    # --- Submodule (child) repo logic ---
    (
        cd "$subdir" || { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Could not cd into ${(q)subdir}"; exit 1; }

        # Generate repo name using helper function
        local repo_name=$(_grepo_name "$PWD" "$custom_repo") || exit 1
        local remote_url=$(_gurl "$user" "$repo_name" "$provider") || exit 1

        # If not a repo, initialize
        ! git rev-parse --is-inside-work-tree &>/dev/null && {
            zshlog --info -v=$GIT_UTILS_DEBUG "⚠️  Initialising git repo in $PWD..." && git init && git branch -M main && zshlog --info -v=$GIT_UTILS_DEBUG "✅ Git initialized"
            zshlog --info -v=$GIT_UTILS_DEBUG "📦 Suggested repo name: $repo_name [$provider]"
            read -r "❓ Proceed with this repo name? [y/N] " reply

            [[ "$reply" != [Yy]* ]] && { zshlog --warn -v=$GIT_UTILS_DEBUG "🚫 Aborted by user"; exit 1; }

            git remote add origin "$remote_url" &&  zshlog --info -v=$GIT_UTILS_DEBUG "🔧 Remote → $remote_url" || { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to add remote"; exit 1; }

            gencrypt_setup "$PWD" true || zshlog --warn -v=$GIT_UTILS_DEBUG "❌ Encryption setup failed or skipped"
        }

        # Prevent parent → child repo contamination
        _gisolate "$PWD"

        # Add and commit submodule repo
        # Try to add files (non-fatal if fails - might already be staged)
        git add . 2>/dev/null && zshlog --info -v=$GIT_UTILS_DEBUG "Files added." || zshlog --info -v=$GIT_UTILS_DEBUG "Files already staged or nothing new to add."

        # Check if there are any changes to commit (staged, unstaged, or untracked)
        local has_staged="$(git diff --cached --name-only)"
        local has_unstaged="$(git diff HEAD --name-only 2>/dev/null)"
        local has_untracked="$(git ls-files --others --exclude-standard)"

        if [[ -n "$has_staged" ]] || [[ -n "$has_unstaged" ]] || [[ -n "$has_untracked" ]]; then
            if ! git commit -m "${commit_msg}"; then
                zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to commit."
                exit 1
            fi
            zshlog --info -v=$GIT_UTILS_DEBUG "Commit: ${commit_msg}"
        elif git rev-parse HEAD >/dev/null 2>&1; then
            zshlog --info -v=$GIT_UTILS_DEBUG "No changes to commit. Proceeding with existing commits..."
        else
            zshlog --info -v=$GIT_UTILS_DEBUG "✅ Submodule repo already complete. Nothing further to do."
            exit 0
        fi

        # Push submodule repo
        git push -u origin main || {
            zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  Push failed. Trying to set upstream..."
            git branch --set-upstream-to=origin/main main 2>/dev/null || true
            git push || {
                zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  Remote repository '$repo_name' not found on $provider"
                local cli_check=$(_gitcli "repo view $user/$repo_name" "$provider") || exit 1
                local cli_create=$(_gitcli "repo create $user/$repo_name --public" "$provider") || exit 1

                if ! eval "$cli_check" &>/dev/null; then
                    zshlog --info -v=$GIT_UTILS_DEBUG "📡 Creating repo via CLI..."
                    if eval "$cli_create"; then
                        zshlog --info -v=$GIT_UTILS_DEBUG "✅ Repo created"
                        git push --set-upstream origin main
                    else
                        zshlog --error -v=$GIT_UTILS_DEBUG "❌ Failed to create remote repository"
                        exit 1
                    fi
                fi
            }
        }
    ) || return 1

    # --- Parent repo logic ---
    (
        cd "$(dirname "$subdir")" || { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Could not cd to parent of $subdir"; exit 1; }

        # Generate parent repo name
        local parent_repo_name=$(_grepo_name "$PWD") || exit 1
        local parent_remote_url=$(_gurl "$user" "$parent_repo_name" "$provider") || exit 1

        # Safety: Only proceed if parent is already a git repo
        ! git rev-parse --is-inside-work-tree &>/dev/null && { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Parent '$PWD' is not a git repo. Aborting submodule add"; exit 1; }

        zshlog --info -v=$GIT_UTILS_DEBUG "\n🔗 Adding submodule: $subdir\n"

        # Add submodule and commit .gitmodules change
        local child_repo_name=$(_grepo_name "$(cd "$subdir" && pwd)") || exit 1
        local child_remote_url=$(_gurl "$user" "$child_repo_name" "$provider") || exit 1

        git submodule add "$child_remote_url" "$subdir"
        [[ -n "$(git status --porcelain .gitmodules 2>/dev/null)" ]] && { git add .gitmodules "$subdir"; git commit -m "${commit_msg} submodule - $subdir"; git push && zshlog --info -v=$GIT_UTILS_DEBUG "✅ Submodule added and parent pushed" && exit 0; } || zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  No changes to .gitmodules detected"
    )

)

# 🌀 gsub-all: Auto-init + add all folders in current dir as submodules except the ones in .gsubignore !
gsub-all() {
    (
        local usage="\n\t⚠️  Usage: gsub-all [-L N|--level=N] [--debug] <commit-message>\n"
        # Preserve the full PATH so git/gh remain accessible
        local original_path=$PATH

        local msg=""
        local level=1
        local debug=0
        local parent_repo="${$(basename "$PWD")#.}"
        local ignore_file=".gsubignore"
        local ignore_list=()
        local args=("$@")

        __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

        # Parse options
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -L|--level)     level="$2";                     shift 2 ;;
                --level=*)      level="${1#*=}";                shift ;;
                --debug)        debug=1;                        shift ;;
                -h|--help)      echo "$usage";                  return 0 ;;
                -*)             zshlog --warn -v=$GIT_UTILS_DEBUG "❌ Unknown option: ${(q)1}";   return 1 ;;
                *)              msg="$1";                       shift ;;
            esac
        done

        # [[ -z "$msg" ]] && echo "\n\t❌ Usage: gsub-all [-L N|--level=N] [--debug] <commit-message>\n" && return 1
        [[ -z "$msg" ]] && echo "$usage" && return 1

        # Enable debug mode if requested
        # [[ $debug -eq 1 ]] && set -x

        # Default ignores
        ignore_list+=("logs" "plugins" "__pycache__" "node_modules" ".DS_Store" ".git" ".idea" ".vscode")

        # Load from .gsubignore if exists
        if [[ -f "$ignore_file" ]]; then
            while IFS= read -r line; do
                line="${line%%\#*}"                             # Strip comments and trim whitespace
                line="${line#"${line%%[![:space:]]*}"}"         # Trim leading whitespace
                line="${line%"${line##*[![:space:]]}"}"         # Trim trailing whitespace
                line="${line%/}"                                # Remove trailing slash if present
                [[ -z "$line" ]] && continue
                ignore_list+=("$line")
            done < "$ignore_file"
        fi

        # Deduplicate ignore_list (zsh builtin)
        typeset -U ignore_list

        # Show what was loaded when running with --debug
        [[ $debug -eq 1 ]] && echo "🔍 Loaded ignore_list: ${ignore_list[*]}"

        # Find all subfolders up to depth
        local subdirs=()
        while IFS= read -r path; do
            dir="${path#./}"  # remove leading ./
            skip=0
            for ignore in "${ignore_list[@]}"; do
                [[ "$dir" == "$ignore" || "$dir" == */"$ignore" ]] && skip=1 && break
            done
            [[ "$skip" -eq 0 ]] && subdirs+=("$dir")
        done < <(find . -mindepth 1 -maxdepth "$level" -type d -not -path "*/.*" -print)

        [[ ${#subdirs[@]} -eq 0 ]] && { echo "⚠️  No directories found to process at depth $level in $PWD"; [[ $debug -eq 1 ]] && set +x; return 0; }

        # Process each valid folder
        for dir in "${subdirs[@]}"; do
            # Skip already-git folders
            # [[ -d "$dir/.git" ]] && continue
            if git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null; then
                # Optional: check if already in .gitmodules
                if grep -q "path = $dir" .gitmodules 2>/dev/null; then
                    echo "⏭️  Skipping $dir — already a submodule."
                    continue
                fi
                echo "⏭️  Skipping $dir — already a Git repo."
                continue
            fi

            echo "📦 Processing $dir..."
            (
                cd "$dir" || return
                # Ensure PATH is restored before calling git/gh
                PATH=$original_path
                grepo "$msg" "${parent_repo}-${dir//\//-}"
            )

            # Ensure PATH is restored before calling git/gh
            PATH=$original_path
            gsub "$dir" "$msg" "${parent_repo}-${dir//\//-}"
        done

        # Disable debug mode before exiting subshell
        [[ $debug -eq 1 ]] && set +x
    )

}

# 🧩 gunsub: Remove a git submodule cleanly
# Usage: gunsub <submodule-path>
# Example:
# > cd ~/.config
# > gunsub brew
gunsub() {
    local name path
    name="$1"
    path="./$name"

    [[ -z "$name" ]] && { echo "Usage: gunsub <submodule-path>"; return 1; }

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    [[ ! -d "$path" ]] && { zshlog --error -v=$GIT_UTILS_DEBUG "❌ No such submodule directory: $path"; return 1; }

    zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  This will completely remove the submodule: $path"
    read -r " Proceed? [y/N]: " REPLY
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && { echo "❎ Cancelled."; return 0; }

    git submodule deinit -f -- "$path" &&
    git rm -f "$path" &&
    rm -rf ".git/modules/$name" &&
    git commit -m "Remove submodule: ${path#./}" &&
    zshlog --info -v=$GIT_UTILS_DEBUG "✅ Submodule removed: $path"

}

# ⚙️ gsync-status: Show sync status for submodule and parent
gsync-status() {
    local parent=$(git rev-parse --show-superproject-working-tree 2>/dev/null)

    read BEHIND AHEAD <<< "$(git rev-list --left-right --count @{u}...HEAD 2>/dev/null || echo "0 0")"; sub_stat="📊 Ahead: $AHEAD, Behind: $BEHIND"
    printf "  📦 Submodule:      %-20s (%s)\n" "$(basename "$PWD")" "$sub_stat"

    read BEHIND AHEAD <<< "$(git -C "$parent" rev-list --left-right --count origin/$(git -C "$parent" rev-parse --abbrev-ref HEAD)...HEAD 2>/dev/null || echo "0 0")"; par_stat="📊 Ahead: $AHEAD, Behind: $BEHIND"
    printf "  📦 Parent Module:  %-20s (%s)\n" "${parent/$HOME/~}" "$par_stat"

    [[ -n "$parent" ]] && echo -e "\n🧩 Parent repo: $parent" && git -C "$parent" status -sb

    echo -e "\n📂 Repository overview:" && git status --short --untracked-files=all
}


# ⚙️ _gsync-push: Push submodule and parent
_gsync-push() {
    # Pushes both submodule and parent repos synchronously.
    # Example: _gsync-push 'Sync config updates'

    local msg="${1:-Sync submodule and parent}"
    _gsubmod "$msg" && _gparent "$msg"
}

# ⚙️ _gsync-pull: Pull latest for both submodule and parent
_gsync-pull() {
    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT
    zshlog --info ${GIT_UTILS_DEBUG:+-v} "📥 Pulling submodule..." && git pull --rebase &&
    zshlog --info ${GIT_UTILS_DEBUG:+-v} "🔗 Reattaching submodules after pull..." && gsub-reattach &&
    zshlog --info ${GIT_UTILS_DEBUG:+-v} "📤 Pulling parent repo..." && ( cd .. && git pull --rebase )
}

# ⚙️ gsync: Full fetch + push
gsync() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n🔁 Usage: gsync [commit-message]\n"
        echo "Performs full fetch + push sync for submodule and parent."
        echo "Example: gsync 'Routine sync'\n"
        return 0
    }
    git fetch --all; gsync-status; _gsync-push "$@"
}

# ⚙️ gsync-all: Recursively push all submodules + parent
gsync-all() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n🌀 Usage: gsync-all [commit-message]\n"
        echo "Recursively syncs all submodules and parent repo.\n"
        echo "Example: gsync-all 'Full system update'\n"
        return 0
    }

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    local msg="${1:-Update all submodules and parent}"
    zshlog --info -v=$GIT_UTILS_DEBUG "🔁 Running gsync-all with commit message: \"$msg\""

    for dir in */.git; do
        local mod="${dir%/.git}"
        zshlog --info -v=$GIT_UTILS_DEBUG "🔄 Syncing submodule: $mod"
        (cd "$mod" && _gsubmod "$msg") || zshlog --error -v=$GIT_UTILS_DEBUG "⚠️ Failed: $mod"
    done

    zshlog --info -v=$GIT_UTILS_DEBUG "🔼 Syncing parent repo..."
    _gparent "$msg"

}


# 🔄 gsub-reattach: Reattach detached submodules to their tracked branch
# After `git submodule update`, submodules are left in detached HEAD state.
# This function checks each submodule and reattaches it to the branch configured
# in .gitmodules (or defaults to 'main') if HEAD matches the branch tip.
# Usage: gsub-reattach [dir=.]
# Example: gsub-reattach ~/.config
gsub-reattach() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n🔄 Usage: gsub-reattach [dir=.]\n"
        echo "Reattaches detached submodules to their tracked branch."
        echo "Checks .gitmodules for configured branch (defaults to main)."
        echo "Only reattaches if HEAD matches the branch tip (safe operation).\n"
        echo "Examples:"
        echo "  gsub-reattach              # Reattach submodules in current dir"
        echo "  gsub-reattach ~/.config    # Reattach submodules in specific dir\n"
        return 0
    }

    local dir="${1:-$PWD}"

    (
        cd "$dir" || return 1

        __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

        # Check if this is a git repo with submodules
        ! git rev-parse --is-inside-work-tree &>/dev/null && {
            zshlog --error -v=$GIT_UTILS_DEBUG "❌ Not a git repo: ${dir/#$HOME/~}"
            return 1
        }
        [[ ! -f .gitmodules ]] && {
            zshlog --info -v=$GIT_UTILS_DEBUG "No .gitmodules found — nothing to reattach"
            return 0
        }

        zshlog --info -v=$GIT_UTILS_DEBUG "🔄 Reattaching detached submodules in ${dir/#$HOME/~}..."

        git submodule foreach --recursive --quiet '
            # Determine the configured branch for this submodule
            branch=$(git config -f "$toplevel/.gitmodules" submodule."$name".branch 2>/dev/null)
            branch="${branch:-main}"

            # Check if currently on a branch or detached
            current=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

            if [ -n "$current" ]; then
                # Already on a branch
                exit 0
            fi

            # Detached HEAD — check if it matches the branch tip
            head_commit=$(git rev-parse HEAD 2>/dev/null)
            branch_commit=$(git rev-parse "origin/$branch" 2>/dev/null || git rev-parse "$branch" 2>/dev/null || echo "")

            if [ -z "$branch_commit" ]; then
                echo "⚠ $name: cannot resolve branch '\''$branch'\'' — skipping"
                exit 0
            fi

            if [ "$head_commit" = "$branch_commit" ]; then
                git checkout "$branch" 2>/dev/null && echo "✓ $name → $branch" || echo "✗ $name: checkout failed"
            else
                short_head=$(git rev-parse --short HEAD)
                short_branch=$(git rev-parse --short "origin/$branch" 2>/dev/null || git rev-parse --short "$branch" 2>/dev/null)
                echo "⚠ $name: detached at $short_head, diverges from $branch ($short_branch) — skipping"
            fi
        '

        zshlog --info ${GIT_UTILS_DEBUG:+-v} "✅ gsub-reattach complete"
    )
}

gsub-genignore() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n📂 Usage: gsub-genignore [target=.]\n"
        echo "Generates or deduplicates .gsubignore for submodule exclusion."
        echo "Example: gsub-genignore ~/.config\n"
        return 0
    }
    local target="${1:-.}"
    local outfile="$target/.gsubignore"
    (( ${+GSUBIGNORE_DEFAULTS} )) || return 1
    # local default_ignores=("logs" "node_modules" "__pycache__" ".venv" ".DS_Store" ".idea" ".vscode" "plugins" "lib" "docs" "bin" "dist" "build" "tmp" "temp" "cache" ".cache" ".git" "save" "saves" "backups" "backup" "env" "venv" "utils" "utility" "utilities" "scripts")
    local msg="# ---\n#   Please add all the folder's that are NOT git submodules\n#   OR do not want them to be a submodule. \
                \n#   Alternatively, edit this file to add/remove folders\n#   that you do\/do not want to make a submodule!\n# ---\n \
                \n# Auto-generated .gsubignore (Not SubModule Candidates)"
    local udirs="\n# === === === === User added folders below: === === === ==="

    setopt local_options null_glob  # 👈 Prevents "no matches found"

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    # Check if file exists and prompt for overwrite
    local regenerate=1
    if [[ -e "$outfile" ]]; then
        read -r "?⚠️  $outfile already exists. Overwrite? [y/N] " reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            zshlog --warn -v=$GIT_UTILS_DEBUG "🚫 Skipped regeneration. Deduplicating existing file...\n"
            regenerate=0
        fi
    fi

    # Generate file only if user approved or file doesn't exist
    if [[ $regenerate -eq 1 ]]; then
        echo "${msg}" > "$outfile"

        zshlog --info -v=$GIT_UTILS_DEBUG "🛠️  Generating ${(q)outfile} with standard ignores..."

        # Collect unique ignores from current directory that match defaults
        local -a found_ignores=()
        for dir in "$target"/*/; do
            dir="${dir%/}"
            name="$(basename "$dir")"
            # for ignore in "${default_ignores[@]}"; do
            for ignore in "${GSUBIGNORE_DEFAULTS[@]}"; do
                [[ "$name" == "$ignore" ]] && found_ignores+=("$name/")
            done
        done

        # Deduplicate using typeset -U
        typeset -U found_ignores
        for ignore in "${found_ignores[@]}"; do
            echo "$ignore" >> "$outfile"
        done

        echo "${udirs}" >> "$outfile"
    else

        zshlog --info -v=$GIT_UTILS_DEBUG "🛠️  Deduplicating existing ${(q)outfile}..."

        # Deduplicate existing file (preserve comments and structure)
        local tempfile="${outfile}.tmp"
        local -a seen_entries=()
        local header_section=1

        while IFS= read -r line; do
            # Always preserve comments and empty lines
            if [[ "$line" =~ ^#.*$ || -z "$line" ]]; then
                echo "$line" >> "$tempfile"
                continue
            fi

            # Normalize: remove trailing slash for comparison
            local normalized="${line%/}"

            # Check if already seen
            if [[ ! " ${seen_entries[@]} " =~ " ${normalized} " ]]; then
                seen_entries+=("$normalized")
                # Preserve original format (with or without trailing slash)
                echo "$line" >> "$tempfile"
            fi
        done < "$outfile"

        mv "$tempfile" "$outfile"
    fi

    # Show the file contents
    [[ $regenerate -eq 1 ]] && zshlog --info -v=$GIT_UTILS_DEBUG "✅ Created ${(q)outfile} with standard ignores.\n" || zshlog --info -v=$GIT_UTILS_DEBUG "✅ Deduplicated ${(q)outfile}.\n"

    echo "📂 Ignored folders:(Not SubModule candidates)"
    \cat "$(realpath "$outfile")"

    # Showing non-ignored folders:
    echo "\n📂 Possible SubModule candidates:(Non-ignored folders)"
    # local ignore_list=("${default_ignores[@]}")
    local ignore_list=("${GSUBIGNORE_DEFAULTS[@]}")
    [[ -f "$outfile" ]] && while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        ignore_list+=("${line%/}")
    done < "$outfile"

    # Deduplicate ignore_list
    typeset -U ignore_list

    local found_non_ignored=0
    for dir in "$target"/*/; do
        dir="${dir%/}"
        name="$(basename "$dir")"
        skip=0

        # Check if directory is a git repository
        ([[ -d "$dir/.git" ]] || git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null) && gitid=" \e[32m(git)\e[0m" || gitid=""

        for ignore in "${ignore_list[@]}"; do
            [[ "$name" == "${ignore%/}" ]] && skip=1 && break
        done
        [[ "$skip" -eq 0 ]] && { echo "    - $name $gitid"; found_non_ignored=1; }
    done

    [[ "$found_non_ignored" -eq 0 ]] && echo "    (none found)"

    # Print default ignorable folders if no ignored or non-ignored folders found
    local ignore_printed=$(grep -Ev '^\s*(#|$)' "$outfile")
    [[ -z "$ignore_printed" && "$found_non_ignored" -eq 0 ]] && { echo "\n📂 Ignorable folders (default set):"; for folder in "${default_ignores[@]}"; do echo "    - $folder/"; done; }

}

# 🔧 gsubignore: Flexibly add/remove folders from .gsubignore user section
# Usage: gsubignore [options] [folder1] [folder2] [-folder3] ...
#   Add folders:     gsubignore logs plugins tmp
#   Remove folders:  gsubignore -logs -plugins (or --remove logs plugins)
#   Wildcards:       gsubignore old* *cache* test-*
#   Mixed:           gsubignore newfolder -oldfolder
#   List entries:    gsubignore -l or --list
#   Clear user:      gsubignore --clear-user
#   Target dir:      gsubignore -d ~/project folder1 folder2
gsubignore() {
    local usage="
    📁 gsubignore - Manage .gsubignore user entries

    Usage: gsubignore [options] [±folder ...]

    Arguments:
    folder        Add folder to ignore list
    -folder       Remove folder from ignore list (prefix with -)
    pattern*      Wildcard patterns supported (matches existing dirs)

    Options:
    -d, --dir DIR     Target directory (default: current)
    -l, --list        List current user-added entries
    -a, --all         List all entries (including auto-generated)
    -c, --clear-user  Clear all user-added entries
    -r, --remove      Remove mode: treat all following args as removals
    -v, --verbose     Verbose output
    -h, --help        Show this help

    Examples:
    gsubignore logs plugins cache     # Add multiple folders
    gsubignore -logs -cache           # Remove folders (- prefix)
    gsubignore --remove logs cache    # Remove folders (--remove flag)
    gsubignore old* *backup*          # Add matching folders via wildcard
    gsubignore -d ~/code tmp          # Add 'tmp' in ~/code/.gsubignore
    gsubignore newfolder -oldfolder   # Add and remove in one command
    gsubignore -l                     # List user-added entries
    gsubignore --clear-user           # Clear user section

    Note: Requires .gsubignore to exist. Run 'gsub-genignore' first to create it.
    "

    # Options
    local target="."
    local list_mode=0
    local list_all=0
    local clear_user=0
    local remove_mode=0
    local verbose=0
    local -a to_add=()
    local -a to_remove=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)          echo "$usage"; return 0 ;;
            -d|--dir)           [[ -z "$2" || "$2" == -* ]] && { echo "❌ --dir requires a directory argument"; return 1; }
                                target="$2";        shift 2 ;;
            --dir=*)            target="${1#*=}";   shift ;;
            -l|--list)          list_mode=1;        shift ;;
            -a|--all)           list_all=1;         shift ;;
            -c|--clear-user)    clear_user=1;       shift ;;
            -r|--remove)        remove_mode=1;      shift ;;
            -v|--verbose)       verbose=1;          shift ;;
            --*)                to_remove+=("${1#--}"); shift ;;  # Long option removal: --foldername (treat as remove)
            -*)
                # Could be short flag combo or removal
                # Check if it's a known short flag
                if [[ "$1" =~ ^-[dlacrvh]+$ ]]; then
                    # Parse combined short flags
                    local flags="${1#-}"
                    for (( i=0; i<${#flags}; i++ )); do
                        case "${flags:$i:1}" in
                            d)
                                [[ -z "$2" || "$2" == -* ]] && { echo "❌ -d requires a directory argument"; return 1; }
                                target="$2";        shift ;;
                            l) list_mode=1 ;;
                            a) list_all=1 ;;
                            c) clear_user=1 ;;
                            r) remove_mode=1 ;;
                            v) verbose=1 ;;
                            h) echo "$usage";       return 0 ;;
                        esac
                    done
                    shift
                else
                    # Treat as removal: -foldername
                    to_remove+=("${1#-}")
                    shift
                fi
                ;;
            *)
                # Regular argument
                if [[ $remove_mode -eq 1 ]]; then
                    to_remove+=("$1")
                else
                    to_add+=("$1")
                fi
                shift
                ;;
        esac
    done

    local outfile="$target/.gsubignore"
    local user_marker="# === === === === User added folders below: === === === ==="

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    # Validate target directory
    [[ ! -d "$target" ]] && { zshlog --error -v=$GIT_UTILS_DEBUG "❌ Directory not found: $target"; return 1; }

    # Check if .gsubignore exists - DO NOT create it
    if [[ ! -f "$outfile" ]]; then
        zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  .gsubignore not found in ${target/#$HOME/~}"
        echo "❌ No .gsubignore file found in ${target/#$HOME/~}"
        echo "💡 Run 'gsub-genignore ${target/#$HOME/~}' first to create it."
        return 1
    fi

    # Check if user section exists
    if ! grep -q "User added folders" "$outfile"; then
        zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  User section not found in .gsubignore"
        echo "⚠️  .gsubignore exists but has no user section marker."
        echo "💡 Add this line to your .gsubignore:"
        echo "   # === === === === User added folders below: === === === ==="
        return 1
    fi

    # LIST MODE: Show entries
    if [[ $list_mode -eq 1 || $list_all -eq 1 ]]; then
        if [[ $list_all -eq 1 ]]; then
            echo "📂 All entries in ${outfile/#$HOME/~}:"
            grep -Ev '^\s*$' "$outfile" | while read -r line; do
                [[ "$line" =~ ^#.*$ ]] && echo "  \e[90m$line\e[0m" || echo "  \e[36m$line\e[0m"
            done
        else
            echo "📂 User-added entries in ${outfile/#$HOME/~}:"
            local in_user_section=0
            local count=0
            while IFS= read -r line; do
                [[ "$line" == *"User added folders"* ]] && { in_user_section=1; continue; }
                if [[ $in_user_section -eq 1 && -n "$line" && ! "$line" =~ ^#.*$ ]]; then
                    echo "  \e[36m${line%/}\e[0m"
                    ((count++))
                fi
            done < "$outfile"
            [[ $count -eq 0 ]] && echo "  (none)"
        fi
        return 0
    fi

    # CLEAR USER MODE: Remove all user entries
    if [[ $clear_user -eq 1 ]]; then
        zshlog --warn -v=$GIT_UTILS_DEBUG "⚠️  Clearing user-added entries..."
        local tempfile="${outfile}.tmp"
        local in_user_section=0

        while IFS= read -r line; do
            if [[ "$line" == *"User added folders"* ]]; then
                echo "$line" >> "$tempfile"
                in_user_section=1
                continue
            fi
            [[ $in_user_section -eq 0 ]] && echo "$line" >> "$tempfile"
        done < "$outfile"

        mv "$tempfile" "$outfile"
        echo "✅ User section cleared"
        echo ""
        echo "📄 Current .gsubignore user entries:"
        echo "   (none)"
        echo ""
        return 0
    fi

    # No folders specified?
    if [[ ${#to_add[@]} -eq 0 && ${#to_remove[@]} -eq 0 ]]; then
        echo "$usage"
        return 1
    fi

    # Enable globbing for wildcard expansion
    setopt local_options null_glob glob_dots

    # =========================================================================
    # VALIDATE INPUT PARAMETERS
    # =========================================================================
    local -a validated_add=()
    local -a skipped_not_dir=()
    local -a skipped_not_found=()

    for item in "${to_add[@]}"; do
        if [[ "$item" == *[\*\?\[]* ]]; then
            # Wildcard - will be expanded later, add as-is for now
            validated_add+=("$item")
        else
            # Literal name - validate it's a directory
            local item_path="$target/${item%/}"
            if [[ -d "$item_path" ]]; then
                validated_add+=("${item%/}")
            elif [[ -e "$item_path" ]]; then
                skipped_not_dir+=("${item%/}")
            else
                skipped_not_found+=("${item%/}")
            fi
        fi
    done

    # Report validation results immediately
    if [[ ${#skipped_not_dir[@]} -gt 0 ]]; then
        echo "\e[90m⏭️  Skipped (not a directory): ${skipped_not_dir[*]}\e[0m"
    fi
    if [[ ${#skipped_not_found[@]} -gt 0 ]]; then
        echo "\e[90m⏭️  Skipped (not found): ${skipped_not_found[*]}\e[0m"
    fi

    # Replace to_add with validated items
    to_add=("${validated_add[@]}")

    # Expand wildcards for additions - DIRECTORIES ONLY
    # (Literal names already validated above)
    local -a expanded_add=()
    for pattern in "${to_add[@]}"; do
        if [[ "$pattern" == *[\*\?\[]* ]]; then
            # Wildcard pattern - expand against existing DIRECTORIES only
            # Use (N/) glob qualifier: N=nullglob, /=directories only
            local -a matches=()
            eval "matches=(\"\$target\"/$~pattern(N/))"
            if [[ ${#matches[@]} -gt 0 ]]; then
                for match in "${matches[@]}"; do
                    expanded_add+=("$(basename "$match")")
                done
                [[ $verbose -eq 1 ]] && echo "🔍 Pattern '$pattern' matched dirs: ${matches[*]##*/}"
            else
                echo "\e[90m⚠️  Pattern '$pattern' matched no directories\e[0m"
            fi
        else
            # Already validated as existing directory - just add
            expanded_add+=("${pattern%/}")
        fi
    done

    # Expand wildcards for removals
    local -a expanded_remove=()
    local -a remove_patterns=()  # Store wildcard patterns for direct matching
    for pattern in "${to_remove[@]}"; do
        if [[ "$pattern" == *[\*\?\[]* ]]; then
            # Store wildcard pattern for later matching during removal
            remove_patterns+=("$pattern")
            # Also try to expand against existing entries in file
            local pattern_matched=0
            while IFS= read -r line; do
                [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
                local entry="${line%/}"
                # Use case for reliable glob pattern matching
                case "$entry" in
                    $~pattern)
                        expanded_remove+=("$entry")
                        pattern_matched=1
                        ;;
                esac
            done < "$outfile"
            [[ $verbose -eq 1 && $pattern_matched -eq 1 ]] && echo "🔍 Remove pattern '$pattern' matched entries"
            [[ $verbose -eq 1 && $pattern_matched -eq 0 ]] && echo "⚠️  Remove pattern '$pattern' matched no entries"
        else
            expanded_remove+=("${pattern%/}")
        fi
    done

    # Track changes for display
    local -a added_entries=()
    local -a removed_entries=()

    # REMOVE entries
    if [[ ${#expanded_remove[@]} -gt 0 || ${#remove_patterns[@]} -gt 0 ]]; then
        local tempfile="${outfile}.tmp"

        # Read all existing entries first to check what exists
        local -a existing_entries=()
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            existing_entries+=("${line%/}")
        done < "$outfile"

        # Check which requested removals don't exist
        local -a not_found_removals=()
        for rem in "${expanded_remove[@]}"; do
            local found=0
            for existing in "${existing_entries[@]}"; do
                [[ "$existing" == "$rem" || "$existing" == "${rem}/" ]] && { found=1; break; }
            done
            [[ $found -eq 0 ]] && not_found_removals+=("$rem")
        done

        # Now process the file
        while IFS= read -r line; do
            local entry="${line%/}"
            local should_remove=0

            # Check against explicit entries
            for rem in "${expanded_remove[@]}"; do
                [[ "$entry" == "$rem" || "$entry" == "${rem}/" ]] && { should_remove=1; break; }
            done

            # Check against wildcard patterns (for entries that might have been missed)
            if [[ $should_remove -eq 0 ]]; then
                for pat in "${remove_patterns[@]}"; do
                    case "$entry" in
                        $~pat) should_remove=1; break ;;
                    esac
                done
            fi

            if [[ $should_remove -eq 1 && ! "$line" =~ ^#.*$ && -n "$line" ]]; then
                removed_entries+=("$entry")
            else
                echo "$line" >> "$tempfile"
            fi
        done < "$outfile"

        mv "$tempfile" "$outfile"

        if [[ ${#removed_entries[@]} -gt 0 ]]; then
            echo "🗑️  Removed: ${removed_entries[*]}"
        fi

        # Report entries not found
        if [[ ${#not_found_removals[@]} -gt 0 ]]; then
            echo "\e[90m⚠️  Not found (skipped): ${not_found_removals[*]}\e[0m"
        fi

        # If nothing was removed and nothing was not-found, show generic message
        if [[ ${#removed_entries[@]} -eq 0 && ${#not_found_removals[@]} -eq 0 && ${#remove_patterns[@]} -gt 0 ]]; then
            echo "\e[90m⚠️  No matching entries found for pattern(s)\e[0m"
        fi
    fi

    # ADD entries to user section
    if [[ ${#expanded_add[@]} -gt 0 ]]; then
        # Read existing entries to avoid duplicates
        local -a existing=()
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            existing+=("${line%/}")
        done < "$outfile"

        local -a skipped_existing=()

        for folder in "${expanded_add[@]}"; do
            folder="${folder%/}"

            # Check if already exists
            if [[ " ${existing[*]} " =~ " ${folder} " ]]; then
                skipped_existing+=("$folder")
                continue
            fi

            # Append to file (will be sorted later)
            echo "${folder}/" >> "$outfile"
            added_entries+=("$folder")
        done

        if [[ ${#added_entries[@]} -gt 0 ]]; then
            echo "✅ Added: ${added_entries[*]}"
        fi

        # Show skipped folders in dim color
        if [[ ${#skipped_existing[@]} -gt 0 ]]; then
            echo "\e[90m⏭️  Skipped (already exist): ${skipped_existing[*]}\e[0m"
        fi
    fi

    # Deduplicate and SORT user section
    local tempfile="${outfile}.tmp"
    local -a seen=()
    local -a user_entries=()
    local in_user_section=0

    # First pass: collect and separate content
    while IFS= read -r line; do
        if [[ "$line" == *"User added folders"* ]]; then
            echo "$line" >> "$tempfile"
            in_user_section=1
            continue
        fi

        if [[ $in_user_section -eq 0 ]]; then
            # Before user section - keep as is (deduplicate)
            if [[ "$line" =~ ^#.*$ || -z "$line" ]]; then
                echo "$line" >> "$tempfile"
            else
                local normalized="${line%/}"
                if [[ ! " ${seen[*]} " =~ " ${normalized} " ]]; then
                    seen+=("$normalized")
                    echo "$line" >> "$tempfile"
                fi
            fi
        else
            # In user section - collect for sorting
            if [[ -n "$line" && ! "$line" =~ ^#.*$ ]]; then
                local normalized="${line%/}"
                if [[ ! " ${seen[*]} " =~ " ${normalized} " ]]; then
                    seen+=("$normalized")
                    user_entries+=("$normalized")
                fi
            fi
        fi
    done < "$outfile"

    # Sort and write user entries
    if [[ ${#user_entries[@]} -gt 0 ]]; then
        printf '%s\n' "${user_entries[@]}" | sort | while read -r entry; do
            echo "${entry}/" >> "$tempfile"
        done
    fi

    mv "$tempfile" "$outfile"

    # Always show current state after modifications
    echo ""
    echo "📄 Current .gsubignore user entries:"
    in_user_section=0
    local entry_count=0
    while IFS= read -r line; do
        [[ "$line" == *"User added folders"* ]] && { in_user_section=1; continue; }
        if [[ $in_user_section -eq 1 && -n "$line" && ! "$line" =~ ^#.*$ ]]; then
            local entry="${line%/}"
            # Highlight newly added entries in green
            if [[ " ${added_entries[*]} " =~ " ${entry} " ]]; then
                echo "   \e[32m${entry} ← new\e[0m"
            else
                echo "   ${entry}"
            fi
            ((entry_count++))
        fi
    done < "$outfile"
    [[ $entry_count -eq 0 ]] && echo "   (none)"

    # Show removed entries (strikethrough effect in dim)
    if [[ ${#removed_entries[@]} -gt 0 ]]; then
        echo ""
        echo "\e[90m   Removed:\e[0m"
        for entry in "${removed_entries[@]}"; do
            echo "   \e[9;31m${entry}\e[0m"
        done
    fi
    echo ""
}

# 🔧 git-genignore: Generate .gitignore for any git repository
git-genignore() {
    local target="${1:-$PWD}"
    local outfile="$target/.gitignore"
    (( ${+GITIGNORE_DEFAULTS} )) || return 1

    __glog_scope_start; trap '__glog_scope_end '"${funcstack[1]}" EXIT

    # Check if directory is a git repo
    if ! git -C "$target" rev-parse --is-inside-work-tree &>/dev/null; then
        zshlog --error -v=$GIT_UTILS_DEBUG "❌ Not a git repository: ${target/#$HOME/~}"
        return 1
    fi

    zshlog --info -v=$GIT_UTILS_DEBUG "🛠️  Generating .gitignore in ${target/#$HOME/~}..."

    # Check if file exists and prompt to overwrite
    local regenerate=1
    if [[ -e "$outfile" ]]; then
        read -r "?⚠️  $outfile already exists. Overwrite? [y/N] " reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            zshlog --warn -v=$GIT_UTILS_DEBUG " 🚫 Skipped regeneration."
            return 0
        else
            local backup_file
            backup_file=$(_backup "$outfile")
            zshlog --info -v=$GIT_UTILS_DEBUG "💾 Backup created at <${backup_file}>"
        fi
    fi

    zshlog --info -v=$GIT_UTILS_DEBUG "🛠️  Generating <${outfile}> with standard ignore patterns..."

    # Generate file
    echo "# .gitignore - Generated by git-genignore" > "$outfile"
    echo "# Add custom patterns below the default sections" >> "$outfile"
    echo "" >> "$outfile"

    # for line in "${default_ignores[@]}"; do
    for line in "${GITIGNORE_DEFAULTS[@]}"; do
        echo "$line" >> "$outfile"
    done

    zshlog --info -v=$GIT_UTILS_DEBUG "✅ Standard ignore patterns added."

    echo "" >> "$outfile"
    echo "# === === === === Custom ignores below: === === === ===" >> "$outfile"

    echo "✅ Created ${outfile/#$HOME/~} with standard ignore patterns."
    echo "📄 File location: ${outfile/#$HOME/~}"
    echo ""
    echo "💡 Tip: Edit the file to add project-specific patterns below the custom section."

}

# Used mainly by git-genignore
# Usage: _backup <target-filename>
# Returns: backup file name
_backup() {
    local target="$1"
    local timestamp=$(date '+%Y%m%d-%H%M%S')
    local backup_file="${target}.${timestamp}.backup"

    cp -r "$target" "$backup_file" || return 1

    echo "$backup_file"
}
