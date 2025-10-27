#!/usr/bin/env zsh
# ~/.config/zsh/git-utils/git-utils.zsh
# ---

# =============================================================================
# 🔧 CORE HELPER FUNCTIONS - Provider-agnostic utilities
# =============================================================================
# Internal utility e.g.: _gituser → returns active git username
local SAVELOGFILE=""
__glog_scope_start() {
    SAVELOGFILE="$LOGFILE"
    export LOGFILE="git-utils.zlog"
    zshlog --info "${1:-${funcstack[2]}}: ↳ Logging Initiated: $(date '+%Y%m%d-%H:%M:%S')"
    # The following ensures the scope-end always runs — even on errors.
    # Better one::  [[ -o interactive ]] || trap '__glog_scope_end ${1:-${funcstack[2]}}' EXIT
    if trap -l | grep -q RETURN; then
        trap '__glog_scope_end ${1:-${funcstack[2]}}' RETURN
    else
        trap '__glog_scope_end ${1:-${funcstack[2]}}' EXIT
    fi
}
__glog_scope_end() {
    zshlog --info "${1:-${funcstack[2]}}: ↩ Concluded Logging at $(date '+%Y%m%d-%H:%M:%S')"
    LOGFILE="$SAVELOGFILE"
    SAVELOGFILE=""
}

# 🏷️  Generate standardized repository name from directory or custom input
# Usage: _grepo_name [dir] [custom_name]
_grepo_name() {

    local dir="${1:-$PWD}" custom="$2"

    __glog_scope_start

    # Return validated custom name if provided
    [[ -n "$custom" ]] && { [[ "$custom" =~ ^[a-zA-Z0-9_-]+$ && ${#custom} -le 40 ]] && { echo "$custom"; return 0; } || { zshlog --error "Invalid repo name: $custom (alphanumeric/hyphens, max 40 chars)"; return 1; }; }

    # Generate from directory: parent-child format
    local base="${dir:t}"           # Get basename (tail)
    local parent="${dir:h:t}"       # Get parent directory name
    base="${base#.}"                # Strip leading dot if present
    parent="${parent#.}"            # Strip leading dot if present
    local name="${parent}-${base}"

    [[ -z "$base" || -z "$parent" ]] && { zshlog --error "Failed to generate repo name from: $dir"; return 1; }

    [[ "$name" == "-" || ${#name} -gt 40 ]] && { zshlog --error "Invalid generated name: $name"; return 1; }

    __glog_scope_end

    echo "$name"
}

# 🌐 Get Git provider (github/gitlab) from GIT_PROVIDER env var
# Usage: _githost
_githost() {
    __glog_scope_start
    local provider="${GIT_PROVIDER:-github}"
    provider="${provider:l}"
    case "$provider" in
        github|gitlab) echo "$provider" ;;
        *) zshlog --warn "Unknown GIT_PROVIDER: $provider, using github"; echo "github" ;;
    esac
    __glog_scope_end
}

# 🔗 Generate SSH remote URL for provider
# Usage: _gurl <username> <repo_name> [provider]
_gurl() {
    __glog_scope_start
    local user="$1" repo="$2" provider="${3:-$(_githost)}"
    [[ -z "$user" || -z "$repo" ]] && { zshlog --error "_gurl requires [username] and [repo_name]"; return 1; }
    case "$provider" in
        github) echo "git@github.com:${user}/${repo}.git" ;;
        gitlab) echo "git@gitlab.com:${user}/${repo}.git" ;;
        *) zshlog --error "Unsupported provider: $provider"; return 1 ;;
    esac
    __glog_scope_end
}

# 🛠️  Get CLI command for provider (gh/glab)
# Usage: _gitcli <command> [provider]
_gitcli() {
    __glog_scope_start
    local cmd="$1" provider="${2:-$(_githost)}"
    case "$provider" in
        github) echo "gh $cmd" ;;
        gitlab) echo "glab $cmd" ;;
        *) zshlog --error "Unsupported provider: $provider"; return 1 ;;
    esac
    __glog_scope_end
}

# 👤 Get username from GITHUB_USER/GITLAB_USER env var
# Usage: _gituser [provider]
_gituser() {
    __glog_scope_start
    local provider="${1:-$(_githost)}"
    case "$provider" in
        github)
            [[ -n "$GITHUB_USER" ]] && { echo "$GITHUB_USER"; return 0; }
            zshlog --error "GITHUB_USER not set" && return 1
            ;;
        gitlab)
            [[ -n "$GITLAB_USER" ]] && { echo "$GITLAB_USER"; return 0; }
            [[ -n "$GITHUB_USER" ]] && { zshlog --warn "GITLAB_USER not set, using GITHUB_USER"; echo "$GITHUB_USER"; return 0; }
            zshlog --error "GITLAB_USER not set" && return 1
            ;;
        *) zshlog --error "Unsupported provider: $provider"; return 1 ;;
    esac
    __glog_scope_end
}

# =============================================================================
# 🔐 ENCRYPTION FUNCTIONS - git-crypt integration
# =============================================================================

# 🔐 Detect if directory contains sensitive files
_gsensitive() {

    __glog_scope_start

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

    zshlog --info -v "🔍 Checking for sensitive files in ${(q)dir/#$HOME/~}..."

    for pattern in "${sensitive_patterns[@]}"; do
        # Use array expansion to check for matches
        local matches=("$dir"/$~pattern)
        if [[ ${#matches[@]} -gt 0 && -e "${matches[1]}" ]]; then
            return 0  # Found sensitive files
        fi
    done
    return 1  # No sensitive files found

    __glog_scope_end

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

    __glog_scope_start

    [[ $# -eq 0 ]] && { zshlog --error -v "No paths given"; return 1; }
    [[ ! -f .gitcrypt ]] && touch .gitcrypt

    if [[ "$folder_mode" == true ]]; then
        for item in "$@"; do
            local pattern="**/${(q)item}/**"
            echo "$pattern" >> .gitcrypt
            zshlog --info "Added folder pattern '$pattern' to .gitcrypt"
        done
    else
        for item in "$@"; do
            local pattern="${(q)item}"
            echo "$pattern" >> .gitcrypt
            zshlog --info "Added file '$pattern' to .gitcrypt"
        done
    fi

    echo "" >> .gitcrypt
    sort -u .gitcrypt -o .gitcrypt
    zshlog --info "✅ .gitcrypt updated (deduplicated)" ; cat .gitcrypt

    __glog_scope_end
}

# 🔐 Setup git-crypt with default sensitive file patterns
# gencrypt_setup() {
#     # local dir="${1:-$PWD}"
#     # local auto="${2:-true}"

#     # (
#     #     cd "$dir" || return 1

#     #     # Check if git-crypt is installed
#     #     ! command -v git-crypt &>/dev/null && { zshlog --warn -v "git-crypt not installed. Skipping encryption setup."; zshlog --info "Install via: brew install git-crypt"; return 1; }

#     #     # Check if already initialized
#     #     [[ -f .git/git-crypt/keys/default ]] && { zshlog --info "git-crypt already initialized in ${dir/#$HOME/~}"; return 0; }

#     #     # Auto mode: only setup if sensitive files detected
#     #     [[ "$auto" == "true" ]] && { ! _gsensitive "$dir" && { zshlog --info "No sensitive files detected. Skipping encryption."; return 0; }; zshlog --info -v "🔐 Sensitive files detected! Setting up encryption automatically..."; } || zshlog --info -v "🔐 Setting up git-crypt encryption..."

#     #     # Initialize git-crypt
#     #     git-crypt init && zshlog --info -v "Folder $dir encryption initialised" || {
#     #         zshlog --error -v "Failed to initialize git-crypt"
#     #         return 1
#     #     }

#     #     # Default sensitive file patterns
#     #     local default_patterns=(
#     #         "**/*.env"
#     #         "**/*.key"
#     #         "**/*.pem"
#     #         "**/*.p12"
#     #         "**/*.pfx"
#     #         "**/*secret*"
#     #         "**/*credential*"
#     #         "**/*password*"
#     #         "**/*.token"
#     #         "**/.ssh/id_*"
#     #         "**/.ssh/*_rsa"
#     #         "**/.gnupg/*.key"
#     #         "**/secrets/"
#     #         "**/credentials/"
#     #     )

#     #     # Load custom patterns from .gitcrypt if exists
#     #     local custom_patterns=()
#     #     if [[ -f .gitcrypt ]]; then
#     #         zshlog --info -v "📋 Loading custom encryption patterns from .gitcrypt..."
#     #         while IFS= read -r line; do
#     #             # Skip comments and empty lines
#     #             line="${line%%\#*}"  # Remove comments
#     #             line="${line#"${line%%[![:space:]]*}"}"  # Trim leading whitespace
#     #             line="${line%"${line##*[![:space:]]}"}"  # Trim trailing whitespace
#     #             [[ -z "$line" ]] && continue
#     #             custom_patterns+=("$line")
#     #             zshlog --info -v "Added custom pattern from .gitcrypt: $line"
#     #         done < .gitcrypt
#     #     fi

#     #     # Combine all patterns
#     #     local all_patterns=("${default_patterns[@]}" "${custom_patterns[@]}")

#     #     # Create or update .gitattributes
#     #     if [[ ! -f .gitattributes ]]; then
#     #         echo "# git-crypt encryption patterns" > .gitattributes
#     #         zshlog --info "Created .gitattributes file"
#     #     else
#     #         # Backup existing
#     #         cp .gitattributes .gitattributes.backup
#     #         zshlog --info "Backed up existing .gitattributes"
#     #         if ! grep -q "git-crypt" .gitattributes; then
#     #             echo "" >> .gitattributes
#     #             echo "# git-crypt encryption patterns" >> .gitattributes
#     #         fi
#     #     fi

#     #     # Add all patterns (default + custom from .gitcrypt)
#     #     local added_count=0
#     #     for pattern in "${all_patterns[@]}"; do
#     #         if ! grep -q "^${pattern}" .gitattributes; then
#     #             echo "${pattern} filter=git-crypt diff=git-crypt" >> .gitattributes
#     #             ((added_count++))
#     #         fi
#     #     done

#     #     local custom_count=${#custom_patterns[@]}
#     #     [[ $custom_count -gt 0 ]] && zshlog --info -v "✅ git-crypt initialized with ${added_count} patterns (${custom_count} from .gitcrypt)" || zshlog --info -v "✅ git-crypt initialized with ${added_count} default patterns"

#     #     # Add .gitattributes to git
#     #     git add .gitattributes
#     #     zshlog --info "Added .gitattributes to git staging"

#     #     zshlog --info -v "✅ Encryption setup complete!"
#     #     zshlog --info "Encrypted files are transparent locally, but encrypted on GitHub."
#     #     [[ $custom_count -gt 0 ]] && zshlog --info -v "ℹ️  Custom patterns loaded from .gitcrypt"

#     #     # Auto-install pre-commit hook (non-interactive)
#     #     gshook "$dir" 2>/dev/null || {
#     #         zshlog --warn "Pre-commit hook installation skipped"
#     #     }
#     # )
# }

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

        __glog_scope_start

        # Check if in git repo and git-crypt installed
        git rev-parse --is-inside-work-tree &>/dev/null || { zshlog --error "Not a git repo or not in one: ${dir/#$HOME/~}"; return 1; }
        command -v git-crypt &>/dev/null || { zshlog --warn "git-crypt not installed. Run: brew install git-crypt"; return 1; }

        # 💣 Force re-init mode
        if [[ "$force" == "true" ]]; then
            zshlog --warn "⚠️  Force mode enabled — removing existing git-crypt data"
            rm -rf .git/git-crypt .gitattributes.backup 2>/dev/null
            git rm --cached .gitattributes 2>/dev/null || true
            git-crypt init && zshlog --info "✅ git-crypt reinitialised (force)" || { zshlog --error "Failed to reinitialise"; return 1; }
        else
            # Normal mode: skip if already initialized otherwise initialize if not fails
            git-crypt status &>/dev/null && zshlog --info "Detected git-crypt setup, skipping init" || {
                git-crypt init && zshlog --info "✅ git-crypt initialised" || {
                    zshlog --error "Failed to init"; return 1;
                };
            }
        fi

        [[ "$auto" == "true" ]] && { _gsensitive "$dir" && zshlog --info "Sensitive files found, updating patterns..." || zshlog --info "No sensitive files found, updating anyway."; }

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
        [[ -f .gitattributes ]] && { cp .gitattributes .gitattributes.backup && zshlog --info "Backed up existing .gitattributes"; } || { echo "# git-crypt encryption patterns" > .gitattributes && zshlog --info "Created .gitattributes"; }

        # Add missing patterns
        local added=0; for p in "${all_patterns[@]}"; do grep -qxF "$p filter=git-crypt diff=git-crypt" .gitattributes || { echo "$p filter=git-crypt diff=git-crypt" >> .gitattributes; ((added++)); }; done
        zshlog --info "✅ Added $added patterns to .gitattributes"

        # Stage .gitattributes for commit
        git add .gitattributes && zshlog --info "Staged .gitattributes"

        # Attempt pre-commit hook installation
        gshook "$dir" 2>/dev/null || zshlog --warn "Skipped hook install"

        zshlog --info "✅ git-crypt setup complete${force:+ (forced)}"

        __glog_scope_end
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
    __glog_scope_start
    ! command -v git-crypt &>/dev/null && { zshlog --error -v "git-crypt not installed"; return 1; }
    [[ ! -f .git/git-crypt/keys/default ]] && { zshlog --error -v "git-crypt not initialised in this repo"; return 1; }
    git-crypt status "$file" &>/dev/null && zshlog --info -v "File: $file - Encrypted ✓" || { zshlog --warn -v "File: $file - Not encrypted"; return 1; }
    __glog_scope_end
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

    __glog_scope_start

    zshlog --info -v "🔍 Scanning for potential secrets in ${dir/#$HOME/~}..."

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
            zshlog --warn "Potential secret detected: $match"
        done < <(git grep -i -n -E "$pattern" 2>/dev/null | head -20)
    done

    [[ $found -eq 0 ]] && zshlog --info -v "✅ No obvious secrets detected" || { echo ""; zshlog --warn -v "⚠️  Review these files and ensure sensitive data is encrypted!"; }

    return $found

    __glog_scope_end
}

# 🔐 Install pre-commit hook for secret scanning
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

        [[ ! -d .git ]] && { zshlog --error -v "Not a git repository: ${dir/#$HOME/~}"; return 1; }

        local hook_file=".git/hooks/pre-commit"

        __glog_scope_start

        # Check if hook already exists
        if [[ -f "$hook_file" ]]; then
            if grep -q "Secret scanning via git-crypt" "$hook_file" 2>/dev/null; then
                zshlog --info "Secret scanning hook already installed"
                return 0
            fi
            # If other hook exists, append silently (non-destructive)
            zshlog --info "Appending secret scanning to existing pre-commit hook"
        fi

        zshlog --info -v "Installing pre-commit secret scanning hook..."

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
        zshlog --info -v "✅ Secret scanning pre-commit hook installed"
        zshlog --info "Hook will scan for secrets before each commit"
        zshlog --info "To bypass: git commit --no-verify (not recommended)"

        __glog_scope_end

    )
}

# =============================================================================
# 🧩 GIT REPO UTILITIES
# =============================================================================

# 🧩 Utility: Isolate a directory as a git repo with .gitignore to prevent parent→child contamination
_gisolate() {
    local dir="${1:-$PWD}"
    (
        __glog_scope_start

        zshlog --info "Entering git repo locally for isolating: ${(q)dir}"
        cd "$dir" || { zshlog --error "❌  Directory not found or in-accessible!"; return 1;}

        if ! git rev-parse --is-inside-work-tree &>/dev/null; then
            zshlog --warn "⚠️  Initializing isolated git repo in $dir..."
            git init || return 1
            git branch -M main || return 1
        fi

        local changed=0
        [[ ! -f .gitignore ]] && {
            zshlog --info "Creating .gitignore to isolate repo ${(q)dir}"
            echo "*" > .gitignore;
            echo "!.gitignore" >> .gitignore; changed=1;
        } || {
            zshlog --info "Updating existing .gitignore to isolate repo ${(q)dir}"
            grep -qxF "*" .gitignore || { echo "*" >> .gitignore; changed=1; };
            grep -qxF "!.gitignore" .gitignore || { echo "!.gitignore" >> .gitignore; changed=1; };
        }

        [[ $changed -eq 1 ]] && {
            git add .gitignore;
            git commit -m "Update .gitignore to isolate repo";
            zshlog --info "✅ .gitignore updated to isolate repo";
        }
        __glog_scope_end
    )
}

# 🧩 Update a submodule (e.g. ~/.config/zsh & ~/.config/zsh/prompt)
gsubmod() {
  local msg="$1"
  local dir="${2:-$PWD}"

  [[ -z "$msg" ]] && { echo "Usage: gsubmod <commit-message> [dir]"; return 1; }

  (
    __glog_scope_start

    cd "$dir" || { zshlog --error "❌  Directory not found or in-accessible!" ; return 1; }
    ! git rev-parse --is-inside-work-tree &>/dev/null && { zshlog --error -v "❌ Not a git repo: ${dir/#$HOME/~}"; return 1; }

    # Try to add files (non-fatal if fails - might already be staged)
    git add . 2>/dev/null && zshlog --info "Files added." || zshlog --info "Files already staged or nothing new to add."

    # Check if there are any changes to commit (staged, unstaged, or untracked)
    local has_staged="$(git diff --cached --name-only)"
    local has_unstaged="$(git diff HEAD --name-only 2>/dev/null)"
    local has_untracked="$(git ls-files --others --exclude-standard)"

    if [[ -n "$has_staged" ]] || [[ -n "$has_unstaged" ]] || [[ -n "$has_untracked" ]]; then
        if ! git commit -m "$msg"; then
            zshlog --error -v "❌ Failed to commit."
            return 1
        fi
        zshlog --info "Commit: $msg"

        # Check for dirty submodules before pushing
        if git submodule status 2>/dev/null | grep -q '^[+]'; then
            zshlog --error -v "❌ Cannot push: submodules have uncommitted changes"
            zshlog --info "💡 Fix: cd into each submodule and run 'gsubmod <msg>'"
            zshlog --info "Dirty submodules:"
            git submodule status | grep '^[+]' | awk '{print "   - " $2}'
            return 1
        fi

        if ! git push; then
            zshlog --error -v "❌ Failed to push."
            return 1
        fi
        zshlog --info -v "✅ Submodule updated in ${dir/#$HOME/~}"
    elif git rev-parse HEAD >/dev/null 2>&1; then
        zshlog --info "No changes to commit. Attempting to push existing commits..."
        git push || zshlog --warn -v "⚠️  No changes to push in: ${dir/#$HOME/~}"
    else
        zshlog --info -v "✅ Submodule already complete. Nothing further to do."
        return 0
    fi

    __glog_scope_end

  )
}

# 🧩 Update parent repo to commit submodule pointer (e.g. ~/.config)
gparent() {
  local msg="$1"
  local dir="${2:-$PWD}"

  [[ -z "$msg" ]] && { echo "Usage: gparent <commit-message> [dir]"; return 1; }

  (
    __glog_scope_start

    cd "$dir" || { zshlog --error "❌  Directory not found or in-accessible!" ; return 1; }
    ! git rev-parse --is-inside-work-tree &>/dev/null && { zshlog --error -v "❌ Not a git repo: ${dir/#$HOME/~}"; return 1; }

    # Try to add files (non-fatal if fails - might already be staged)
    git add . 2>/dev/null && zshlog --info "Submodule pointers added." || zshlog --info "Submodule pointers already staged or nothing new to add."

    # Check if there are any changes to commit (staged, unstaged, or untracked)
    local has_staged="$(git diff --cached --name-only)"
    local has_unstaged="$(git diff HEAD --name-only 2>/dev/null)"
    local has_untracked="$(git ls-files --others --exclude-standard)"

    if [[ -n "$has_staged" ]] || [[ -n "$has_unstaged" ]] || [[ -n "$has_untracked" ]]; then
        if ! git commit -m "$msg"; then
            zshlog --error -v "❌ Failed to commit."
            return 1
        fi
        zshlog --info "Commit: $msg"

        # Check for dirty submodules before pushing
        if git submodule status 2>/dev/null | grep -q '^[+]'; then
            zshlog --error -v "❌ Cannot push: submodules have uncommitted changes"
            zshlog --info "💡 Fix: cd into each submodule and run 'gsubmod <msg>'"
            zshlog --info "Dirty submodules:"
            git submodule status | grep '^[+]' | awk '{print "   - " $2}'
            return 1
        fi

        if ! git push; then
            zshlog --error -v "❌ Failed to push."
            return 1
        fi
        zshlog --info -v "✅ Parent repo updated with submodule pointers in ${dir/#$HOME/~}"
    elif git rev-parse HEAD >/dev/null 2>&1; then
        zshlog --info "No changes to submodule pointers. Attempting to push existing commits..."
        git push || zshlog --warn -v "⚠️  No changes to push in: ${dir/#$HOME/~}"
    else
        zshlog --info -v "✅ Parent repo already complete. Nothing further to do."
        return 0
    fi

    __glog_scope_end

  )
}

# ---
# Usage: grepo [commit_msg] [optional_path]
# Example: grepo "Initial commit" "repo-stuff/my-new-repo/"

grepo() (
    local usage="\n\t❗ Usage: grepo [ [-h|--help] | [commit_msg] [repo_name] ]\n"
    [[ "$1" == (-h|--help|-help|/\?) ]] && { echo "$usage"; return 0; }
    [[ $# -gt 2 ]] && { echo "$usage"; return 1; }

    __glog_scope_start

    # Generate repo name and get provider info using helper functions
    local commit_msg="${1:-Initial commit}" dir="$PWD"
    local repo_name=$(_grepo_name "$dir" "$2") || return 1
    local provider=$(_githost)
    local user=$(_gituser "$provider") || return 1
    local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")

    # User validation
    echo "ℹ️  Running: grepo <$repo_name> \"$commit_msg\" → ${dir/#$HOME/~} [$provider]"
    read -r "?❓ Proceed? [y/N] " reply
    [[ ! "$reply" =~ ^[Yy]$ ]] && { zshlog --warn "🚫 Aborted by user"; return 1; }

    echo "📦 Repository: $user/$repo_name"
    read -r "?❓ Proceed? [y/N] " reply
    [[ ! "$reply" =~ ^[Yy]$ ]] && { zshlog --warn "🚫 Repo name rejected"; return 1; }

    # Initialize git repo if needed
    git rev-parse --is-inside-work-tree &>/dev/null || {
        zshlog --info -v "⚠️  Initializing git repo in ${dir/#$HOME/~}..."; git init &&
        zshlog --info -v "✅  Git repo initialized." &&
        git branch -M main || {
            zshlog --error -v "❌  Failed to initialize git repo."; return 1;
        };
    }

    # Auto-setup encryption if sensitive files detected
    gencrypt_setup "$dir" true || {
        zshlog --warn "⚠️  Encryption setup failed or skipped ⁉️ "
    }

    # Check and set remote using helper function
    local remote_url=$(_gurl "$user" "$repo_name" "$provider") || return 1
    git remote get-url origin &>/dev/null && { local current_remote=$(git remote get-url origin); [[ "$current_remote" != "$remote_url" ]] && { git remote set-url origin "$remote_url" || { zshlog --error -v "❌ Failed to update remote"; return 1; }; }; zshlog --info -v "⚠️  Remote 'origin' → $current_remote"; } || { git remote add origin "$remote_url" || { zshlog --error -v "❌ Failed to set remote"; return 1; }; zshlog --info -v "✅ Remote 'origin' → $remote_url"; }

    # Prevent parent → child repo contamination
    _gisolate "$dir"

    # Add and commit files
    zshlog --info -v "💫 Adding files from ${dir/#$HOME/~} to $repo_name.git..."

    # Try to add files (non-fatal if fails - might already be staged)
    git add . 2>/dev/null && zshlog --info "Files added." || zshlog --info "Files already staged or nothing new to add."

    # Check if there are any changes to commit (staged, unstaged, or untracked)
    local has_staged="$(git diff --cached --name-only)"
    local has_unstaged="$(git diff HEAD --name-only 2>/dev/null)"
    local has_untracked="$(git ls-files --others --exclude-standard)"

    if [[ -n "$has_staged" ]] || [[ -n "$has_unstaged" ]] || [[ -n "$has_untracked" ]]; then
        if ! git commit -m "$commit_msg"; then
            zshlog --error -v "❌ Failed to commit."
            return 1
        fi
        zshlog --info "Commit: $commit_msg"
    elif git rev-parse HEAD >/dev/null 2>&1; then
        zshlog --info "No changes to commit. Proceeding with existing commits..."
    else
        zshlog --info -v "✅ Local repo already complete. Nothing further to do."
        return 0
    fi

    # Check if remote already has commits
    if [[ -n "$(git ls-remote origin HEAD 2>/dev/null)" ]]; then
        zshlog --info -v "⚠️  Remote has commits. Attempting to merge..."

        # Try regular pull first
        if ! git pull --no-rebase origin "$current_branch" 2>/dev/null; then
            # If that fails, try with --allow-unrelated-histories
            if ! git pull --no-rebase --allow-unrelated-histories origin "$current_branch"; then
                zshlog --error -v "❌ Failed to pull from remote."
                return 1
            fi
        fi

        # Check for merge conflicts
        if ! git diff --check &>/dev/null || [[ -n "$(git ls-files -u)" ]]; then
            zshlog --warn -v "⚠️  Merge conflicts detected. Resolving automatically..."

            # Auto-resolve: keep local versions (--ours)
            git checkout --ours . 2>/dev/null
            git add -A
            git commit --no-edit 2>/dev/null || git commit -m "Merge remote with local changes (keeping local)" 2>/dev/null

            zshlog --info -v "✅ Conflicts auto-resolved (kept local versions)"
        fi
    fi

    # Push to remote
    git push -u origin "$current_branch" || {
        zshlog --warn -v "⁉️  Push failed for '$user/$repo_name'. Checking remote repo..."
        local cli_check=$(_gitcli "repo view $user/$repo_name" "$provider") || return 1
        local cli_create=$(_gitcli "repo create $user/$repo_name --public" "$provider") || return 1

        eval "$cli_check" &>/dev/null || {
            zshlog --info -v "📡 Creating repo $user/$repo_name on $provider..."
            eval "$cli_create" && {
                zshlog --info -v "✅ Repo created"
                git push -u origin "$current_branch" || { zshlog --error -v "❌ Push failed after repo creation"; return 1; }
            } || { zshlog --error -v "❌ Failed to create repo"; return 1; }
        } || { zshlog --error -v "❌ Push failed for unknown reasons"; return 1; }
    }

    zshlog --info -v "✅ Successfully pushed to $user/$repo_name"

    # Update parent repo if it's a git repo
    parent_dir=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$parent_dir" && -d "$parent_dir/.git" ]]; then
        (cd "$parent_dir" && gparent "Update submodule pointer: $repo_name")
    else
        zshlog --warn -v "⚠️  Skipping parent module update — not in a Git repo."
    fi

    __glog_scope_end

)

# 🧩 Git utility for submodules
# Usage: gsub <folder> [commit_msg] [repo_name]
# Example: gsub "repo-stuff/my-new-repo/" "Adding submodule - repo-stuff/my-new-repo/"

gsub() (
    local usage="\n\t⚠️  Usage: gsub <subdirectory> [<commit_msg> = 'Adding' [<repo_name>]]\n"
    [[ "$1" == (-h|--help|-help|/\?) ]] && { echo "$usage"; return 0; }

    local subdir="$1" commit_msg="${2:-Adding}" custom_repo="$3"
    [[ -z "$subdir" ]] && { echo "$usage"; return 1; }

    __glog_scope_start

    # Get provider info
    local provider=$(_githost)
    local user=$(_gituser "$provider") || { zshlog --error "❌  User ${(q)user}\@${(q)provider} not found!" ; return 1; }

    # --- Submodule (child) repo logic ---
    (
        cd "$subdir" || { zshlog --error "❌ Could not cd into ${(q)subdir}"; exit 1; }

        # Generate repo name using helper function
        local repo_name=$(_grepo_name "$PWD" "$custom_repo") || exit 1
        local remote_url=$(_gurl "$user" "$repo_name" "$provider") || exit 1

        # If not a repo, initialize
        ! git rev-parse --is-inside-work-tree &>/dev/null && {
            zshlog --info -v "⚠️  Initialising git repo in $PWD..." && git init && git branch -M main && zshlog --info -v "✅ Git initialized"
            zshlog --info -v "📦 Suggested repo name: $repo_name [$provider]"
            read -r "❓ Proceed with this repo name? [y/N] " reply

            [[ "$reply" != [Yy]* ]] && { zshlog --warn "🚫 Aborted by user"; exit 1; }

            git remote add origin "$remote_url" &&  zshlog --info -v "🔧 Remote → $remote_url" || { zshlog --error "❌ Failed to add remote"; exit 1; }

            gencrypt_setup "$PWD" true || zshlog --warn "❌ Encryption setup failed or skipped"
        }

        # Prevent parent → child repo contamination
        _gisolate "$PWD"

        # Add and commit submodule repo
        # Try to add files (non-fatal if fails - might already be staged)
        git add . 2>/dev/null && zshlog --info "Files added." || zshlog --info "Files already staged or nothing new to add."

        # Check if there are any changes to commit (staged, unstaged, or untracked)
        local has_staged="$(git diff --cached --name-only)"
        local has_unstaged="$(git diff HEAD --name-only 2>/dev/null)"
        local has_untracked="$(git ls-files --others --exclude-standard)"

        if [[ -n "$has_staged" ]] || [[ -n "$has_unstaged" ]] || [[ -n "$has_untracked" ]]; then
            if ! git commit -m "${commit_msg}"; then
                zshlog --error -v "❌ Failed to commit."
                exit 1
            fi
            zshlog --info "Commit: ${commit_msg}"
        elif git rev-parse HEAD >/dev/null 2>&1; then
            zshlog --info "No changes to commit. Proceeding with existing commits..."
        else
            zshlog --info -v "✅ Submodule repo already complete. Nothing further to do."
            exit 0
        fi

        # Push submodule repo
        git push -u origin main || {
            zshlog --warn "⚠️  Push failed. Trying to set upstream..."
            git branch --set-upstream-to=origin/main main 2>/dev/null || true
            git push || {
                zshlog --warn "⚠️  Remote repository '$repo_name' not found on $provider"
                local cli_check=$(_gitcli "repo view $user/$repo_name" "$provider") || exit 1
                local cli_create=$(_gitcli "repo create $user/$repo_name --public" "$provider") || exit 1

                if ! eval "$cli_check" &>/dev/null; then
                    zshlog --info -v "📡 Creating repo via CLI..."
                    if eval "$cli_create"; then
                        zshlog --info -v "✅ Repo created"
                        git push --set-upstream origin main
                    else
                        zshlog --error "❌ Failed to create remote repository"
                        exit 1
                    fi
                fi
            }
        }
    ) || return 1

    # --- Parent repo logic ---
    (
        cd "$(dirname "$subdir")" || { zshlog --error "❌ Could not cd to parent of $subdir"; exit 1; }

        # Generate parent repo name
        local parent_repo_name=$(_grepo_name "$PWD") || exit 1
        local parent_remote_url=$(_gurl "$user" "$parent_repo_name" "$provider") || exit 1

        # Safety: Only proceed if parent is already a git repo
        ! git rev-parse --is-inside-work-tree &>/dev/null && { zshlog --error "❌ Parent '$PWD' is not a git repo. Aborting submodule add"; exit 1; }

        zshlog --info -v "\n🔗 Adding submodule: $subdir\n"

        # Add submodule and commit .gitmodules change
        local child_repo_name=$(_grepo_name "$(cd "$subdir" && pwd)") || exit 1
        local child_remote_url=$(_gurl "$user" "$child_repo_name" "$provider") || exit 1

        git submodule add "$child_remote_url" "$subdir"
        [[ -n "$(git status --porcelain .gitmodules 2>/dev/null)" ]] && { git add .gitmodules "$subdir"; git commit -m "${commit_msg} submodule - $subdir"; git push && zshlog --info -v "✅ Submodule added and parent pushed" && exit 0; } || zshlog --warn "⚠️  No changes to .gitmodules detected"
    )

    __glog_scope_end

)

# 🌀 gsub-all: Auto-init + add all folders in current dir as submodules
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

        __glog_scope_start

        # Parse options
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -L|--level)     level="$2";                     shift 2 ;;
                --level=*)      level="${1#*=}";                shift ;;
                --debug)        debug=1;                        shift ;;
                -h|--help)      echo "$usage";                  return 0 ;;
                -*)             zshlog --warn -v "❌ Unknown option: ${(q)1}";   return 1 ;;
                *)              msg="$1";                       shift ;;
            esac
        done

        # [[ -z "$msg" ]] && echo "\n\t❌ Usage: gsub-all [-L N|--level=N] [--debug] <commit-message>\n" && return 1
        [[ -z "$msg" ]] && echo "$usage" && return 1

        # Enable debug mode if requested
        [[ $debug -eq 1 ]] && set -x

        # Default ignores
        ignore_list+=("logs" "plugins" "__pycache__" "node_modules" ".DS_Store" ".git" ".idea" ".vscode")

        # Load from .gsubignore if exists
        if [[ -f "$ignore_file" ]]; then
            while IFS= read -r line; do
                # Strip comments and trim whitespace
                line="${line%%\#*}"
                # Trim leading whitespace
                line="${line#"${line%%[![:space:]]*}"}"
                # Trim trailing whitespace
                line="${line%"${line##*[![:space:]]}"}"
                # Remove trailing slash if present
                line="${line%/}"
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

    __glog_scope_end

}

# Usage: gunsub <submodule-path>
# Example:
# > cd ~/.config
# > gunsub brew
gunsub() {
    local name path
    name="$1"
    path="./$name"

    [[ -z "$name" ]] && { echo "Usage: gunsub <submodule-path>"; return 1; }

    __glog_scope_start

    [[ ! -d "$path" ]] && { zshlog --error -v "❌ No such submodule directory: $path"; return 1; }

    zshlog --warn -v "⚠️  This will completely remove the submodule: $path"
    read -r " Proceed? [y/N]: " REPLY
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && { echo "❎ Cancelled."; return 0; }

    git submodule deinit -f -- "$path" &&
    git rm -f "$path" &&
    rm -rf ".git/modules/$name" &&
    git commit -m "Remove submodule: ${path#./}" &&
    zshlog --info -v "✅ Submodule removed: $path"

    __glog_scope_end

}

# ⚙️ gsync-status: Show sync status for submodule and parent
gsync-status() {
    local parent_dir=$(git rev-parse --show-superproject-working-tree 2>/dev/null)

    read BEHIND AHEAD <<< "$(git rev-list --left-right --count @{u}...HEAD 2>/dev/null || echo "0 0")"; sub_stat="📊 Ahead: $AHEAD, Behind: $BEHIND"
    printf "  📦 Submodule:      %-20s (%s)\n" "$(basename "$PWD")" "$sub_stat"

    read BEHIND AHEAD <<< "$(git -C "$parent" rev-list --left-right --count origin/$(git -C "$parent" rev-parse --abbrev-ref HEAD)...HEAD 2>/dev/null || echo "0 0")"; par_stat="📊 Ahead: $AHEAD, Behind: $BEHIND"
    printf "  📦 Parent Module:  %-20s (%s)\n" "${parent_dir/$HOME/~}" "$par_stat"

    [[ -n "$parent" ]] && echo -e "\n🧩 Parent repo: $parent" && git -C "$parent" status -sb

    echo -e "\n📂 Repository overview:" && git status --short --untracked-files=all
}


# ⚙️ gsync-push: Push submodule and parent
gsync-push() {
    # [[ "$1" == (-h|--help) ]] && {
    #     echo "\n🔼 Usage: gsync-push [commit-message]\n"
    #     echo "Pushes both submodule and parent repos synchronously."
    #     echo "Example: gsync-push 'Sync config updates'\n"
    #     return 0
    # }
    local msg="${1:-Sync submodule and parent}"
    gsubmod "$msg" && gparent "$msg"
}

# ⚙️ gsync-pull: Pull latest for both submodule and parent
gsync-pull() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n📥 Usage: gsync-pull\n"
        echo "Pulls latest changes for submodule and parent repo.\n"
        return 0
    }
    echo "📥 Pulling submodule..." && git pull --rebase &&
    echo "📤 Pulling parent repo..." && cd .. && git pull --rebase
}

# ⚙️ gsync: Full fetch + push
gsync() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n🔁 Usage: gsync [commit-message]\n"
        echo "Performs full fetch + push sync for submodule and parent."
        echo "Example: gsync 'Routine sync'\n"
        return 0
    }
    git fetch --all; gsync-status; gsync-push "$@"
}

# ⚙️ gsync-all: Recursively push all submodules + parent
gsync-all() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n🌀 Usage: gsync-all [commit-message]\n"
        echo "Recursively syncs all submodules and parent repo.\n"
        echo "Example: gsync-all 'Full system update'\n"
        return 0
    }

    __glog_scope_start

    local msg="${1:-Update all submodules and parent}"
    zshlog --info -v "🔁 Running gsync-all with commit message: \"$msg\""

    for dir in */.git; do
        local mod="${dir%/.git}"
        zshlog --info -v "🔄 Syncing submodule: $mod"
        (cd "$mod" && gsubmod "$msg") || zshlog --error -v "⚠️ Failed: $mod"
    done

    zshlog --info -v "🔼 Syncing parent repo..."
    gparent "$msg"

    __glog_scope_end

}

# 🔧 gsub-genignore: Generate .gsubignore based on directory contents
gsub-genignore() {
    [[ "$1" == (-h|--help) ]] && {
        echo "\n📂 Usage: gsub-genignore [target=.]\n"
        echo "Generates or deduplicates .gsubignore for submodule exclusion."
        echo "Example: gsub-genignore ~/.config\n"
        return 0
    }
    local target="${1:-.}"
    local outfile="$target/.gsubignore"
    local default_ignores=("logs" "node_modules" "__pycache__" ".venv" ".DS_Store" ".idea" ".vscode" "plugins" "lib" "docs" "bin" "dist" "build" "tmp" "temp" "cache" ".cache" ".git" "save" "saves" "backups" "backup" "env" "venv" "utils" "utility" "utilities" "scripts")
    local msg="# ---\n#   Please add all the folder's that are NOT git submodules\n#   OR do not want them to be a submodule. \
                \n#   Alternatively, edit this file to add/remove folders\n#   that you do\/do not want to make a submodule!\n# ---\n \
                \n# Auto-generated .gsubignore (Not SubModule Candidates)"
    local udirs="\n# === === === === User added folders below: === === === ==="

    setopt local_options null_glob  # 👈 Prevents "no matches found"

    __glog_scope_start

    # Check if file exists and prompt for overwrite
    local regenerate=1
    if [[ -e "$outfile" ]]; then
        read -r "?⚠️  $outfile already exists. Overwrite? [y/N] " reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            zshlog --warn -v "🚫 Skipped regeneration. Deduplicating existing file...\n"
            regenerate=0
        fi
    fi

    # Generate file only if user approved or file doesn't exist
    if [[ $regenerate -eq 1 ]]; then
        echo "${msg}" > "$outfile"

        zshlog --info -v "🛠️  Generating ${(q)outfile} with standard ignores..."

        # Collect unique ignores from current directory that match defaults
        local -a found_ignores=()
        for dir in "$target"/*/; do
            dir="${dir%/}"
            name="$(basename "$dir")"
            for ignore in "${default_ignores[@]}"; do
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

        zshlog --info -v "🛠️  Deduplicating existing ${(q)outfile}..."

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
    [[ $regenerate -eq 1 ]] && zshlog --info -v "✅ Created ${(q)outfile} with standard ignores.\n" || zshlog --info -v "✅ Deduplicated ${(q)outfile}.\n"

    echo "📂 Ignored folders:(Not SubModule candidates)"
    \cat "$(realpath "$outfile")"

    # Showing non-ignored folders:
    echo "\n📂 Possible SubModule candidates:(Non-ignored folders)"
    local ignore_list=("${default_ignores[@]}")
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

    __glog_scope_end

}

# 🔧 git-genignore: Generate .gitignore for any git repository
git-genignore() {
    local target="${1:-$PWD}"
    local outfile="$target/.gitignore"
    local default_ignores=(
        "# OS generated files"
        ".DS_Store"
        ".DS_Store?"
        "._*"
        ".Spotlight-V100"
        ".Trashes"
        "ehthumbs.db"
        "Thumbs.db"
        ""
        "# Editor directories and files"
        ".idea/"
        ".vscode/"
        "*.swp"
        "*.swo"
        "*~"
        ""
        "# Logs and databases"
        "*.log"
        "logs/"
        "*.sql"
        "*.sqlite"
        ""
        "# Dependencies and build artifacts"
        "node_modules/"
        "dist/"
        "build/"
        "*.pyc"
        "__pycache__/"
        ".venv/"
        "venv/"
        "env/"
        ""
        "# Temporary files"
        "*.tmp"
        "tmp/"
        "temp/"
        "cache/"
        ".cache/"
        ""
        "# Security and secrets"
        "*.env"
        ".env"
        ".env.*"
        "*.key"
        "*.pem"
        "secrets/"
        "credentials/"
    )

    __glog_scope_start

    # Check if directory is a git repo
    if ! git -C "$target" rev-parse --is-inside-work-tree &>/dev/null; then
        zshlog --error "❌ Not a git repository: ${target/#$HOME/~}"
        return 1
    fi

    zshlog --info "🛠️  Generating .gitignore in ${target/#$HOME/~}..."

    # Check if file exists and prompt for overwrite
    local regenerate=1
    if [[ -e "$outfile" ]]; then
        read -r "?⚠️  $outfile already exists. Overwrite? [y/N] " reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            echo "🚫 Skipped regeneration."
            return 0
        fi
    fi

    zshlog --info "🛠️  Generating ${(q)outfile} with standard ignore patterns..."

    # Generate file
    echo "# .gitignore - Generated by git-genignore" > "$outfile"
    echo "# Add custom patterns below the default sections" >> "$outfile"
    echo "" >> "$outfile"

    for line in "${default_ignores[@]}"; do
        echo "$line" >> "$outfile"
    done

    zshlog --info "✅ Standard ignore patterns added."

    echo "" >> "$outfile"
    echo "# === === === === Custom ignores below: === === === ===" >> "$outfile"

    echo "✅ Created $outfile with standard ignore patterns."
    echo "📄 File location: ${outfile/#$HOME/~}"
    echo ""
    echo "💡 Tip: Edit the file to add project-specific patterns below the custom section."

    __glog_scope_end

}
