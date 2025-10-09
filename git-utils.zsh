#!/usr/bin/env zsh
# ~/.config/zsh/git-utils/git-utils.zsh
# ---

# =============================================================================
# 🔧 CORE HELPER FUNCTIONS - Provider-agnostic utilities
# =============================================================================

# 🏷️  Generate standardized repository name from directory or custom input
# Usage: grepo_name [dir] [custom_name]
grepo_name() {
    local dir="${1:-$PWD}" custom="$2"

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

    echo "$name"
}

# 🌐 Get Git provider (github/gitlab) from GIT_PROVIDER env var
# Usage: githost
githost() {
    local provider="${GIT_PROVIDER:-github}"
    provider="${provider:l}"
    case "$provider" in
        github|gitlab) echo "$provider" ;;
        *) zshlog --warn "Unknown GIT_PROVIDER: $provider, using github"; echo "github" ;;
    esac
}

# 🔗 Generate SSH remote URL for provider
# Usage: gurl <username> <repo_name> [provider]
gurl() {
    local user="$1" repo="$2" provider="${3:-$(githost)}"
    [[ -z "$user" || -z "$repo" ]] && { zshlog --error "gurl requires [username] and [repo_name]"; return 1; }
    case "$provider" in
        github) echo "git@github.com:${user}/${repo}.git" ;;
        gitlab) echo "git@gitlab.com:${user}/${repo}.git" ;;
        *) zshlog --error "Unsupported provider: $provider"; return 1 ;;
    esac
}

# 🛠️  Get CLI command for provider (gh/glab)
# Usage: gitcli <command> [provider]
gitcli() {
    local cmd="$1" provider="${2:-$(githost)}"
    case "$provider" in
        github) echo "gh $cmd" ;;
        gitlab) echo "glab $cmd" ;;
        *) zshlog --error "Unsupported provider: $provider"; return 1 ;;
    esac
}

# 👤 Get username from GITHUB_USER/GITLAB_USER env var
# Usage: gituser [provider]
gituser() {
    local provider="${1:-$(githost)}"
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
}

# =============================================================================
# 🔐 ENCRYPTION FUNCTIONS - git-crypt integration
# =============================================================================

# 🔐 Detect if directory contains sensitive files
gsensitive() {
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

    for pattern in "${sensitive_patterns[@]}"; do
        # Use array expansion to check for matches
        local matches=("$dir"/$~pattern)
        if [[ ${#matches[@]} -gt 0 && -e "${matches[1]}" ]]; then
            return 0  # Found sensitive files
        fi
    done
    return 1  # No sensitive files found
}

# 🔐 Setup git-crypt with default sensitive file patterns
gencrypt_setup() {
    local dir="${1:-$PWD}"
    local auto="${2:-true}"

    (
        cd "$dir" || return 1

        # Check if git-crypt is installed
        ! command -v git-crypt &>/dev/null && { zshlog --warn -v "git-crypt not installed. Skipping encryption setup."; zshlog --info "Install via: brew install git-crypt"; return 1; }

        # Check if already initialized
        [[ -f .git/git-crypt/keys/default ]] && { zshlog --info "git-crypt already initialized in ${dir/#$HOME/~}"; return 0; }

        # Auto mode: only setup if sensitive files detected
        [[ "$auto" == "true" ]] && { ! gsensitive "$dir" && { zshlog --info "No sensitive files detected. Skipping encryption."; return 0; }; zshlog --info -v "🔐 Sensitive files detected! Setting up encryption automatically..."; } || zshlog --info -v "🔐 Setting up git-crypt encryption..."

        # Initialize git-crypt
        git-crypt init || {
            zshlog --error -v "Failed to initialize git-crypt"
            return 1
        }

        # Default sensitive file patterns
        local default_patterns=(
            "*.env"
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
            "secrets/"
            "credentials/"
        )

        # Load custom patterns from .gitkeys if exists
        local custom_patterns=()
        if [[ -f .gitkeys ]]; then
            zshlog --info -v "📋 Loading custom encryption patterns from .gitkeys..."
            while IFS= read -r line; do
                # Skip comments and empty lines
                line="${line%%\#*}"  # Remove comments
                line="${line#"${line%%[![:space:]]*}"}"  # Trim leading whitespace
                line="${line%"${line##*[![:space:]]}"}"  # Trim trailing whitespace
                [[ -z "$line" ]] && continue
                custom_patterns+=("$line")
                zshlog --info "Added custom pattern from .gitkeys: $line"
            done < .gitkeys
        fi

        # Combine all patterns
        local all_patterns=("${default_patterns[@]}" "${custom_patterns[@]}")

        # Create or update .gitattributes
        if [[ ! -f .gitattributes ]]; then
            echo "# git-crypt encryption patterns" > .gitattributes
            zshlog --info "Created .gitattributes file"
        else
            # Backup existing
            cp .gitattributes .gitattributes.backup
            zshlog --info "Backed up existing .gitattributes"
            if ! grep -q "git-crypt" .gitattributes; then
                echo "" >> .gitattributes
                echo "# git-crypt encryption patterns" >> .gitattributes
            fi
        fi

        # Add all patterns (default + custom from .gitkeys)
        local added_count=0
        for pattern in "${all_patterns[@]}"; do
            if ! grep -q "^${pattern}" .gitattributes; then
                echo "${pattern} filter=git-crypt diff=git-crypt" >> .gitattributes
                ((added_count++))
            fi
        done

        local custom_count=${#custom_patterns[@]}
        [[ $custom_count -gt 0 ]] && zshlog --info -v "✅ git-crypt initialized with ${added_count} patterns (${custom_count} from .gitkeys)" || zshlog --info -v "✅ git-crypt initialized with ${added_count} default patterns"

        # Add .gitattributes to git
        git add .gitattributes
        zshlog --info "Added .gitattributes to git staging"

        zshlog --info -v "✅ Encryption setup complete!"
        zshlog --info "Encrypted files are transparent locally, but encrypted on GitHub."
        [[ $custom_count -gt 0 ]] && zshlog --info -v "ℹ️  Custom patterns loaded from .gitkeys"

        # Auto-install pre-commit hook (non-interactive)
        gshook "$dir" 2>/dev/null || {
            zshlog --warn "Pre-commit hook installation skipped"
        }
    )
}

# 🔐 Check if a file would be encrypted
gencrypt_check() {
    local file="$1"
    [[ -z "$file" ]] && { echo "Usage: gencrypt_check <file>"; return 1; }

    ! command -v git-crypt &>/dev/null && { zshlog --error -v "git-crypt not installed"; return 1; }

    [[ ! -f .git/git-crypt/keys/default ]] && { zshlog --error -v "git-crypt not initialized in this repo"; return 1; }

    git-crypt status "$file" 2>/dev/null && {
        zshlog --info -v "File: $file - Encrypted ✓"
    } || {
        zshlog --warn -v "File: $file - Not encrypted"
        return 1
    }
}

# 🔐 Scan for potential secrets in unencrypted files
gsecrets() {
    local dir="${1:-$PWD}"

    zshlog --info -v "🔍 Scanning for potential secrets..."

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
}

# 🔐 Install pre-commit hook for secret scanning
gshook() {
    local dir="${1:-$PWD}"

    (
        cd "$dir" || return 1

        [[ ! -d .git ]] && { zshlog --error -v "Not a git repository: ${dir/#$HOME/~}"; return 1; }

        local hook_file=".git/hooks/pre-commit"

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
    )
}

# =============================================================================
# 🧩 GIT REPO UTILITIES
# =============================================================================

# 🧩 Utility: Isolate a directory as a git repo with .gitignore to prevent parent→child contamination
gisolate() {
    local dir="${1:-$PWD}"
    (
        cd "$dir" || return 1
        if ! git rev-parse --is-inside-work-tree &>/dev/null; then
            echo "⚠️  Initializing isolated git repo in $dir..."
            git init || return 1
            git branch -M main || return 1
        fi

        local changed=0
        [[ ! -f .gitignore ]] && { echo "*" > .gitignore; echo "!.gitignore" >> .gitignore; changed=1; } || { grep -qxF "*" .gitignore || { echo "*" >> .gitignore; changed=1; }; grep -qxF "!.gitignore" .gitignore || { echo "!.gitignore" >> .gitignore; changed=1; }; }

        [[ $changed -eq 1 ]] && { git add .gitignore; git commit -m "Update .gitignore to isolate repo"; }
    )
}

# 🧩 Update a submodule (e.g. ~/.config/zsh & ~/.config/zsh/prompt)
gsubmod() {
  local msg="$1"
  local dir="${2:-$PWD}"

  [[ -z "$msg" ]] && { echo "Usage: gsubmod <commit-message> [dir]"; return 1; }

  (
    cd "$dir" || return 1
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
  )
}

# 🧩 Update parent repo to commit submodule pointer (e.g. ~/.config)
gparent() {
  local msg="$1"
  local dir="${2:-$PWD}"

  [[ -z "$msg" ]] && { echo "Usage: gparent <commit-message> [dir]"; return 1; }

  (
    cd "$dir" || return 1
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
  )
}

# ---
# Usage: grepo [commit_msg] [optional_path]
# Example: grepo "Initial commit" "repo-stuff/my-new-repo/"

grepo() (
    local usage="\n\t❗ Usage: grepo [ [-h|--help] | [commit_msg] [repo_name] ]\n"
    [[ "$1" == (-h|--help|-help|/\?) ]] && { echo "$usage"; return 0; }
    [[ $# -gt 2 ]] && { echo "$usage"; return 1; }

    # Generate repo name and get provider info using helper functions
    local commit_msg="${1:-Initial commit}" dir="$PWD"
    local repo_name=$(grepo_name "$dir" "$2") || return 1
    local provider=$(githost)
    local user=$(gituser "$provider") || return 1
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
    local remote_url=$(gurl "$user" "$repo_name" "$provider") || return 1
    git remote get-url origin &>/dev/null && { local current_remote=$(git remote get-url origin); [[ "$current_remote" != "$remote_url" ]] && { git remote set-url origin "$remote_url" || { zshlog --error -v "❌ Failed to update remote"; return 1; }; }; zshlog --info -v "⚠️  Remote 'origin' → $current_remote"; } || { git remote add origin "$remote_url" || { zshlog --error -v "❌ Failed to set remote"; return 1; }; zshlog --info -v "✅ Remote 'origin' → $remote_url"; }

    # Prevent parent → child repo contamination
    gisolate "$dir"

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
        local cli_check=$(gitcli "repo view $user/$repo_name" "$provider") || return 1
        local cli_create=$(gitcli "repo create $user/$repo_name --public" "$provider") || return 1

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
)

# 🧩 Git utility for submodules
# Usage: gsub <folder> [commit_msg] [repo_name]
# Example: gsub "repo-stuff/my-new-repo/" "Adding submodule - repo-stuff/my-new-repo/"

gsub() (
    local usage="\n\t⚠️  Usage: gsub <subdirectory> [<commit_msg> = 'Adding' [<repo_name>]]\n"
    [[ "$1" == (-h|--help|-help|/\?) ]] && { echo "$usage"; return 0; }

    local subdir="$1" commit_msg="${2:-Adding}" custom_repo="$3"
    [[ -z "$subdir" ]] && { echo "$usage"; return 1; }

    # Get provider info
    local provider=$(githost)
    local user=$(gituser "$provider") || return 1

    # --- Submodule (child) repo logic ---
    (
        cd "$subdir" || { zshlog --error "❌ Could not cd into $subdir"; exit 1; }

        # Generate repo name using helper function
        local repo_name=$(grepo_name "$PWD" "$custom_repo") || exit 1
        local remote_url=$(gurl "$user" "$repo_name" "$provider") || exit 1

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
        gisolate "$PWD"

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
                local cli_check=$(gitcli "repo view $user/$repo_name" "$provider") || exit 1
                local cli_create=$(gitcli "repo create $user/$repo_name --public" "$provider") || exit 1

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
        local parent_repo_name=$(grepo_name "$PWD") || exit 1
        local parent_remote_url=$(gurl "$user" "$parent_repo_name" "$provider") || exit 1

        # Safety: Only proceed if parent is already a git repo
        ! git rev-parse --is-inside-work-tree &>/dev/null && { zshlog --error "❌ Parent '$PWD' is not a git repo. Aborting submodule add"; exit 1; }

        zshlog --info -v "\n🔗 Adding submodule: $subdir\n"

        # Add submodule and commit .gitmodules change
        local child_repo_name=$(grepo_name "$(cd "$subdir" && pwd)") || exit 1
        local child_remote_url=$(gurl "$user" "$child_repo_name" "$provider") || exit 1

        git submodule add "$child_remote_url" "$subdir"
        [[ -n "$(git status --porcelain .gitmodules 2>/dev/null)" ]] && { git add .gitmodules "$subdir"; git commit -m "${commit_msg} submodule - $subdir"; git push && zshlog --info -v "✅ Submodule added and parent pushed" && exit 0; } || zshlog --warn "⚠️  No changes to .gitmodules detected"
    )
)

# gsub() (
#     local usage="\n\t❌ Usage: gsub <subdirectory> [<commit_msg> = 'Adding' [<repo_name>]]\n"
#     [[ "$1" == (-h|--help|-help|/\?) ]] && { echo "$usage"; return 0; }

#     local subdir="$1" commit_msg="${2:-Adding}" repo_name="$3"
#     [[ -z "$subdir" ]] && echo $usage && return 1

#     # Check for required GitHub user variable
#     local gh_user
#     if [[ -n "$GITHUB_USER" ]]; then
#         gh_user="$GITHUB_USER"
#     else
#         echo "❌ GITHUB_USER environment variable is not set. Please set your GitHub username in GITHUB_USER."
#         echo "   For security, never commit this variable into any repository."
#         return 1
#     fi

#     # Always operate on the submodule directory first, then add as submodule in parent
#     (
#         cd "$subdir" || { echo "❌ Could not cd into $subdir"; exit 1; }

#         # Prepare repo name and remote url
#         local   cleaned_subdir="${subdir:t}"
#                 cleaned_subdir="${cleaned_subdir#.}"
#         local   cleaned_base="${PWD:h:t}"
#                 cleaned_base="${cleaned_base#.}"
#         local   submodule_name="${cleaned_base}-${cleaned_subdir}"

#         local parentname="${PWD:h:t}"
#         local grandparent="${PWD:h:h:t}"
#         local parent_clean="${parentname//./}"
#         local grandparent_clean="${grandparent//./}"
#         local remote_repo="${repo_name:-${grandparent_clean}-${parent_clean}}"
#         local remote_url="git@github.com:${gh_user}/${remote_repo}.git"

#         # If not a repo, initialize
#         if ! git rev-parse --is-inside-work-tree &>/dev/null; then
#             echo "❌ $PWD is not a Git repository."
#             echo "⚠️  Initialising git repo in $PWD..." && git init && git branch -M main && echo "\t... ✅ $PWD initialised."
#             [[ -z "$parent_clean" || -z "$grandparent_clean" ]] && {
#                 echo "❌ Could not determine parent/grandparent folder names."
#                 exit 1
#             }
#             echo "📦 Suggested GitHub repo name: $remote_repo"
#             read -r "?❓ Proceed with this repo name? [y/N] " reply
#             [[ "$reply" != [Yy]* ]] && echo "🚫 Aborted by user [ name-choice ]." && exit 1
#             git remote add origin "$remote_url" &&
#             echo "🔧 Set remote: $remote_url"
#         fi

#         # Prevent parent → child repo contamination
#         git_isolate_repo "$PWD"

#         # Add, commit and push submodule repo
#         git add . &&
#         git commit -m "${commit_msg}" &&
#         git push -u origin main || {
#             echo "⚠️  Push failed. Trying to set upstream..."
#             git branch --set-upstream-to=origin/main main 2>/dev/null || true
#             git push || {
#                 echo "⚠️  Remote repository '${remote_repo}' not found on GitHub."
#                 if ! gh repo view "$gh_user/$remote_repo" &>/dev/null; then
#                     echo "📡 Creating repo via GitHub CLI..."
#                     if gh repo create "$gh_user/$remote_repo" --public --confirm; then
#                         echo "✅ Repo created."
#                         git push --set-upstream origin main
#                     else
#                         echo "❌ Failed to create remote repository. Aborting."
#                         exit 1
#                     fi
#                 fi
#             }
#         }
#     ) || return 1

#     # Now add submodule to parent repo
#     (
#         cd .. || { echo "❌ Could not cd to parent of $subdir"; exit 1; }
#         # Set up submodule name and remote again
#         local   cleaned_subdir="${subdir:t}"
#                 cleaned_subdir="${cleaned_subdir#.}"
#         local   cleaned_base="${PWD:t}"
#                 cleaned_base="${cleaned_base#.}"
#         local submodule_name="${cleaned_base}-${cleaned_subdir}"

#         local parentname="${PWD:t}"
#         local grandparent="${PWD:h:t}"
#         local parent_clean="${parentname//./}"
#         local grandparent_clean="${grandparent//./}"
#         local remote_repo="${repo_name:-${grandparent_clean}-${parent_clean}}"
#         local remote_url="git@github.com:${gh_user}/${remote_repo}.git"

#         echo "\n🔗 Adding submodule: \"$submodule_name\"\n"

#         git submodule add "$remote_url" "$subdir"
#         git commit -am " ${commit_msg} submodule - $subdir"
#         git push && echo "✅ Submodule added and parent pushed." && exit 0

#         echo "⚠️  Push failed. Trying to set upstream..."
#         git branch --set-upstream-to=origin/main main 2>/dev/null || true
#         git push || {
#             echo "⚠️  Remote repository '${remote_repo}' not found on GitHub."
#             if ! gh repo view "$gh_user/$remote_repo" &>/dev/null; then
#                 echo "📡 Creating repo via GitHub CLI..."
#                 if gh repo create "$gh_user/$remote_repo" --public --confirm; then
#                     echo "✅ Repo created."
#                     git push --set-upstream origin main
#                 else
#                     echo "❌ Failed to create remote repository. Aborting."
#                     exit 1
#                 fi
#             fi
#         }
#     )
# )

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

        # Parse options
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -L|--level)
                    level="$2"
                    shift 2
                    ;;
                --level=*)
                    level="${1#*=}"
                    shift
                    ;;
                --debug)
                    debug=1
                    shift
                    ;;
                -h|--help)
                    echo "$usage"
                    return 0
                    ;;
                -*)
                    echo "❌ Unknown option: $1"
                    return 1
                    ;;
                *)
                    msg="$1"
                    shift
                    ;;
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

    [[ ! -d "$path" ]] && { echo "❌ No such submodule directory: $path"; return 1; }

    echo "⚠️  This will completely remove the submodule: $path"
    read -r " Proceed? [y/N]: " REPLY
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && { echo "❎ Cancelled."; return 0; }

    git submodule deinit -f -- "$path" &&
    git rm -f "$path" &&
    rm -rf ".git/modules/$name" &&
    git commit -m "Remove submodule: ${path#./}" &&
    echo "✅ Submodule removed: $path"
}

# ⚙️ gsync-push: Push submodule and parent
gsync-push() {
  local msg="${1:-Sync submodule and parent}"
  gsubmod "$msg" && gparent "$msg"
}

# ⚙️ gsync-pull: Pull latest for both submodule and parent
gsync-pull() {
  echo "📥 Pulling submodule..."
  git pull --rebase && echo "📤 Pulling parent repo..." && cd .. && git pull --rebase
}

# ⚙️ gsync: Full fetch + push
gsync() {
  git fetch --all
  gsync-status
  gsync-push "$@"
}

# ⚙️ gsync-all: Recursively push all submodules + parent
gsync-all() {
  local msg="${1:-Update all submodules and parent}"
  echo "🔁 Running gsync-all with commit message: \"$msg\""

  for dir in */.git; do
    local mod="${dir%/.git}"
    echo "🔄 Syncing submodule: $mod"
    (cd "$mod" && gsubmod "$msg") || echo "⚠️ Failed: $mod"
  done

  echo "🔼 Syncing parent repo..."
  gparent "$msg"
}

# 🔧 gsub-genignore: Generate .gsubignore based on directory contents
gsub-genignore() {
    local target="${1:-.}"
    local outfile="$target/.gsubignore"
    local default_ignores=("logs" "node_modules" "__pycache__" ".venv" ".DS_Store" ".idea" ".vscode" "plugins" "lib" "docs" "bin" "dist" "build" "tmp" "temp" "cache" ".cache" ".git" "save" "saves" "backups" "backup" "env" "venv" "utils" "utility" "utilities" "scripts")
    local msg="# ---\n#   Please add all the folder's that are NOT git submodules\n#   OR do not want them to be a submodule. \
                \n#   Alternatively, edit this file to add/remove folders\n#   that you do not want to make a submodule!\n# ---\n \
                \n# Auto-generated .gsubignore (Not SubModule Candidates)"
    local udirs="\n# === === === === User added folders below: === === === ==="

    setopt local_options null_glob  # 👈 Prevents "no matches found"

    # Check if file exists and prompt for overwrite
    local regenerate=1
    if [[ -e "$outfile" ]]; then
        read -r "?⚠️  $outfile already exists. Overwrite? [y/N] " reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            echo "🚫 Skipped regeneration. Deduplicating existing file...\n"
            regenerate=0
        fi
    fi

    # Generate file only if user approved or file doesn't exist
    if [[ $regenerate -eq 1 ]]; then
        echo "${msg}" > "$outfile"

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
    [[ $regenerate -eq 1 ]] && echo "✅ Created $outfile with standard ignores.\n" || echo "✅ Deduplicated $outfile.\n"
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
}
