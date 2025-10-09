# 🧩 git-utils — NOMAD Dotfiles Git Workflow

> Minimal, fast Zsh helpers for monorepo + submodule workflows in a `.config`-centred setup. Built to work cleanly on macOS/Linux with **GitHub & GitLab**. **Now with built-in encryption support via git-crypt!** 🔐

---

## 📁 Overview

This toolkit assumes a `~/.config` repo where key subfolders (e.g. `zsh`, `brew`, `prompt`) may be their **own Git repos** and connected to the parent via **Git submodules**.

***Goals:***
- Initialise and push new config folders quickly
- Add them as submodules in the parent
- Keep the parent's submodule pointers in sync
- Provide status-aware sync commands for daily use
- **🔐 Automatically encrypt sensitive files with git-crypt**
- **🌐 Support both GitHub and GitLab providers**

> **New:** All functions are individual executables in `~/.config/zsh/git-utils/` and loaded via PATH (fast on-demand loading!).

---

## 🚀 Quick Setup (NEW Structure)

**This toolkit uses PATH-based autoloading for fast shell startup:**

1. **Add to your shell config** (`~/.config/zsh/zsh-exports`):
   ```bash
   export_path "$HOME/.config/zsh/git-utils"
   ```

2. **Comment out old loading** (in `~/.config/zsh/.zshrc` line 64):
   ```bash
   # zsh_add_file "git-utils/git-utils.zsh"  # OLD: No longer needed
   ```

3. **Reload shell:**
   ```bash
   exec zsh
   ```

4. **Test:**
   ```bash
   which grepo gsub gsync  # Should show paths in git-utils/
   ```

**What changed:**
- ✅ Functions are now individual executable files (not sourced)
- ✅ Loaded on-demand via PATH (90%+ faster shell startup)
- ✅ Original file archived as `git-utils.zsh.arc` for reference

---

## ✅ Requirements

- **git** (SSH configured for GitHub/GitLab)
- **GitHub CLI `gh`** OR **GitLab CLI `glab`** for repo creation:
  ```bash
  # GitHub
  brew install gh
  gh auth login

  # GitLab (optional)
  brew install glab
  glab auth login
  ```
- **git-crypt** (optional but recommended) for encryption:
  ```bash
  brew install git-crypt
  ```
- **GPG** (optional) for sharing encrypted repos:
  ```bash
  brew install gnupg
  ```
- Zsh completion (optional) for nicer UX (see "Tab Completion").

---

## 🌐 Multi-Provider Support

Set your Git provider using environment variables:

```bash
# In ~/.config/zsh/my.zshenv or ~/.zshrc
export GIT_PROVIDER="github"    # or "gitlab" (default: github)
export GITHUB_USER="yourusername"
export GITLAB_USER="yourusername"  # optional, falls back to GITHUB_USER
```

The toolkit will automatically use the correct:
- SSH URL format (`git@github.com:...` or `git@gitlab.com:...`)
- CLI tool (`gh` or `glab`)
- Remote repository host

⸻

## 🔧 Core Helper Functions

These compact one-liner functions provide provider-agnostic utilities:

### `grepo_name [dir] [custom_name]`
Generate/validate standardized repository names.
- Auto-generates from directory structure (parent-child format)
- Validates custom names (alphanumeric/hyphens, max 40 chars)

### `githost`
Get current Git provider (`github` or `gitlab`) from `GIT_PROVIDER` env var.

### `gurl <username> <repo_name> [provider]`
Generate SSH remote URL for the specified provider:
- `git@github.com:user/repo.git` (GitHub)
- `git@gitlab.com:user/repo.git` (GitLab)

### `gitcli <command> [provider]`
Get CLI command for provider (`gh` or `glab`).

### `gituser [provider]`
Get username from `GITHUB_USER`/`GITLAB_USER` env vars.

**Example:**
```bash
# Get provider-specific info
provider=$(githost)           # "github" or "gitlab"
user=$(gituser)               # Your username
url=$(gurl "$user" "myrepo")  # git@github.com:user/myrepo.git
cli=$(gitcli "repo list")     # "gh repo list" or "glab repo list"
```

⸻

## 🔐 Encryption Functions

**Note:** Encryption functions have been renamed with shorter names:
- `git_setup_encryption` → `gencrypt_setup`
- `git_check_encryption` → `gencrypt_check`
- `git_scan_secrets` → `gsecrets`
- `git_has_sensitive_files` → `gsensitive` (internal)
- `git_install_secret_hook` → `gshook` (internal)

### `gencrypt_setup [dir] [auto]`
Setup git-crypt encryption with sensible defaults for sensitive files.

**Default encrypted patterns:**
- `*.env`, `*.key`, `*.pem`, `*.token` - Credentials
- `*secret*`, `*credential*`, `*password*` - Sensitive configs
- `.ssh/id_*`, `.gnupg/*.key` - SSH/GPG keys
- AWS keys, GitHub tokens (pattern-based)

**Custom patterns via `.gitkeys` file:**
Create a `.gitkeys` file in your repo root to add project-specific encryption patterns:

```bash
# .gitkeys example
# Add custom encryption patterns (one per line)
*.backup
config.local.json
internal/
.auth.yml
jwt.txt
```

**Features:**
- Automatic detection of sensitive files
- Loads custom patterns from `.gitkeys` if present
- Automatic pre-commit hook installation
- Transparent encryption (files readable locally, encrypted on GitHub)

### `gencrypt_check <file>`
Check if a specific file is encrypted by git-crypt.

### `gsecrets [dir]`
Scan repository for potential unencrypted secrets. Checks for common patterns like API keys, passwords, tokens.

**Example:**
```bash
cd ~/.config/myapp

# Create .gitkeys for custom patterns (optional)
cat > .gitkeys <<EOF
# Custom encryption patterns
*.backup
config.local.json
internal/
EOF

# Create sensitive files
touch .env config.local.json

# Encryption happens automatically during grepo/gsub
grepo "Initial commit"
# 🔐 Sensitive files detected! Setting up encryption automatically...
# 📋 Loading custom encryption patterns from .gitkeys...
# ✅ git-crypt initialized with 17 patterns (3 from .gitkeys)

# Verify encryption
git_check_encryption .env              # Check if .env is encrypted
git_check_encryption config.local.json # Check custom file
git_scan_secrets                       # Scan for any exposed secrets
```

⸻

## 🚀 Repository Commands
```bash
grepo [repo_name] [commit_msg]
```
Create and push a new Git repo to GitHub from the current folder.
If the remote doesn't exist, it's created via gh.
**Now prompts for encryption setup!**

### Examples
```bash
cd ~/.config/zsh
grepo zsh-config "Initial commit"
```

⸻
```bash
gsub <folder> [commit_msg] [repo_name]
```
Initialise <folder> as a submodule, push its repo to GitHub (if needed), and update the parent repo pointer.

### Examples
```sh
cd ~/.config
gsub brew "Add Homebrew config" brew-config
```
What it handles for you:
- Submodule add (`.gitmodules` + `.git/config`)
- Initial commit in child (if needed)
- Push to remote (child), then commit pointer in parent

⸻
```sh
gunsub <folder>
```
Fully remove a submodule and clean references.

### Examples
```sh
cd ~/.config
gunsub prompt
```
What it cleans:
- Removes `<folder>`,
- Updates `.gitmodules`, `.git/config`
    - `git rm --cached <folder>` and related metadata
- Leaves no dangling submodule state

⸻

These are used internally by the the other modules
```sh
git_submodule [msg]
git_parentmodule [msg]
```
⸻

## 🔄 `gsync` Commands (Daily Drivers)

|*Command*	      |*What it does*|
|-----------------|-------------------------|
|`gsync-status`	  |Shows ahead/behind for current submodule and parent
|`gsync`	      |fetch → status → push (submodule first, then parent pointer if changed)
|`gsync-push`	  |Commit & push both: submodule (if changes) then parent pointer
|`gsync-pull`	  |Pull submodule first then parent (safe order to avoid pointer drift)
|`gsync-all`	  |Run git_submodule on all submodules, then update and push the parent pointer


Tip: If your docs/scripts mention `gupdate` and `gsubupdate`, map them like this:

*Optional wrappers (keep behaviour explicit and memorable)*
```sh
alias gupdate='gsync-pull'
alias gsubupdate='gsync-all'
```

⸻

## 🔤 Tab Completion (Zsh)

If completions are enabled, drop `_gutils` into `~/.config/zsh/completions/` and load it:
```sh
~/.config/zsh/completions/_gutils
```
                - #compdef
                - gsub
                - grepo
                - gsync
                - gsync-push
                - gsync-pull
                - gsync-all
                - gsync-status
                - gunsub
                - git_submodule
                - git_parentmodule

Load via your plugin system:
```sh
zsh_add_completion "$ZDOTDIR/completions/_gutils"
```

⸻

## 📦 ### Examples Workflow

 1) Create a new module and push it
    ```sh
    cd ~/.config/zsh/prompt
    grepo prompt-zsh "Initial commit"
    ```

 2) Add it as submodule under the parent
    ```sh
    cd ~/.config
    gsub zsh/prompt "Add prompt config" prompt-zsh
    ```
 3) Make changes inside the submodule
    ```sh
    cd ~/.config/zsh/prompt
    ```
    ...edit files...
    ```sh
    git_submodule "Refine prompt segments"
    ```
 4) Update the parent pointer
    ```sh
    cd ~/.config
    git_parentmodule "Point to latest prompt"
    ```
 5) Or just use the sync helpers
    ```sh
    gsync-push
    ```

⸻

## 📁 Recommended Structure
```sh
.config/
├── zsh/                   → github.com/smnuman/zsh-config
│   └── prompt/            → github.com/smnuman/prompt-zsh
├── brew/                  → github.com/smnuman/brew-config
└── dotconfig-zsh/         → parent repo hosting all submodules
```

*Note: ` prompt/` as a nested submodule under ` zsh/` is supported.*

⸻

## 🛡️ Safety & Defaults
- Uses SSH remotes (e.g. ***git@github.com:username/repo.git***) where possible.
- Default branch expected: main (respects your Git defaults if set).
- Orders operations to avoid pointer drift (submodule first, then parent).
- Clear status checks before destructive operations (e.g. gunsub).
- **Automatic merge conflict resolution** (see below).

### 🔀 Automatic Conflict Resolution

When `grepo` detects existing commits in the remote repository, it automatically handles merge conflicts:

**Behavior:**
1. Attempts standard merge (`git pull --no-rebase`)
2. If unrelated histories exist, merges with `--allow-unrelated-histories`
3. **Auto-resolves conflicts** by keeping local versions (`git checkout --ours`)
4. Creates merge commit automatically

**Why this is safe:**
- You're initializing/syncing your local config to remote
- Local version is your source of truth during setup
- Prevents manual intervention during batch operations (`gsub-all`)
- Conflicts are logged for review if needed

**When conflicts occur:**
- Remote has initial commit (e.g., README, LICENSE from GitHub)
- Local has different initial commit (e.g., Brewfile)
- Solution: Merge both, prioritize local files

**Example scenario:**
```bash
# Remote has: README.md (from GitHub)
# Local has: Brewfile, .gitignore
# Result: All three files merged, local files preserved
```

**Bypass automatic resolution:**
If you need manual control, modify `grepo()` line 495-518 in `git-utils.zsh`.

**Testing:**
Run the test suite to verify conflict resolution works:
```bash
~/.config/docs/zsh/git/TEST.SUITE.06.autoConflictResolution.zsh
```

⸻

## 🔧 Integration with Docs

Your `~/.config/docs/setup.md` can refer to:
- `gsync-pull` for updating the environment (or the `gupdate alias` above)
- `gsync-all` for refreshing all submodules (or the `gsubupdate alias` above)
- `gsub` / `gunsub` for managing submodules
- `git_parentmodule` when pinning pointer updates explicitly

⸻

## 🧠 Author & Licence

                Built by @smnuman
                MIT Licence — use, modify, share freely
