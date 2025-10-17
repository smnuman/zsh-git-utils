# Git Utils — Zsh Modular Toolkit

A collection of **Git workflow helpers, git-crypt integration, and submodule utilities** designed for a modular Zsh environment.
This file documents the functions in `git-utils.zsh` located under `~/.config/zsh/git-utils/`.

---

## 📌 Prerequisites

Before using these functions, ensure:

- **Zsh environment** is fully loaded with:
  - `$ZDOTDIR` set correctly
  - `$BREWDOTS/.env` sourced (Homebrew binaries available)
- **Required binaries installed**:
  - `git`
  - `git-crypt` (optional, for encryption)
  - `gh` (GitHub CLI) and/or `glab` (GitLab CLI)
  - `jq` (for parsing GitLab API output)
- **Environment variables** set:
  - `GIT_PROVIDER` (default: `"github"`)
  - `GITHUB_USER` or `GITLAB_USER`
  - `$PATH` includes CLI binaries (`gh`, `glab`, `git-crypt`)

---

## 🛠️ Function Workflow Overview

The workflow proceeds in **layers**, reflecting how functions depend on each other:

1. **Core Helper Functions** → Determine repo names, providers, user names, and remote URLs.
2. **Encryption Functions** → Detect sensitive files, initialize git-crypt, scan secrets, and install hooks.
3. **Repository Utilities** → Isolate directories, initialize repos, add/commit/push.
4. **Submodule Utilities** → Add, commit, push, remove, and sync submodules.
5. **Sync Utilities** → Push/pull changes for submodules and parent repositories.
6. **Ignore Utilities** → Auto-generate `.gitignore` and `.gsubignore` for repo hygiene.

---

## 🔧 Core Helper Functions

| Function | Usage | Description |
|----------|-------|-------------|
| `grepo_name [dir] [custom_name]` | `grepo_name ~/Projects/foo "custom-repo"` | Generate a valid repo name from directory or custom name (alphanumeric/hyphens, max 40 chars) |
| `githost` | `githost` | Returns current Git provider (`github` or `gitlab`) |
| `gurl <user> <repo> [provider]` | `gurl "$GITHUB_USER" "my-repo"` | Returns SSH remote URL for repo |
| `gitcli <command> [provider]` | `gitcli "repo view"` | Returns provider CLI command, e.g., `gh repo view` or `glab repo view` |
| `gituser [provider]` | `gituser github` | Returns `$GITHUB_USER` or `$GITLAB_USER`; warns/falls back if missing |

**Requirements:**
- `$GITHUB_USER` or `$GITLAB_USER` must be set.
- CLI tools must be installed and in `$PATH`.

---

## 🔐 Encryption Functions (git-crypt)

| Function | Usage | Description |
|----------|-------|-------------|
| `gsensitive [dir]` | `gsensitive ~/Projects/foo` | Checks if sensitive files exist in directory (env, key, token patterns) |
| `gencrypt_setup [dir] [auto]` | `gencrypt_setup ~/Projects/foo true` | Initializes git-crypt if sensitive files found; `auto=true` skips if no sensitive files |
| `gencrypt_check <file>` | `gencrypt_check secrets/.env` | Checks if a specific file is encrypted |
| `gsecrets [dir]` | `gsecrets ~/Projects/foo` | Scans unencrypted files for potential secrets |
| `gshook [dir]` | `gshook ~/Projects/foo` | Installs pre-commit hook to prevent committing secrets |

**Requirements:**
- `git-crypt` installed.
- Repository initialized with `git init`.
- Optional `.gitkeys` file to customize sensitive file patterns.

---

## 📦 Repository Utilities

| Function | Usage | Description |
|----------|-------|-------------|
| `gisolate [dir]` | `gisolate ~/Projects/foo` | Adds `.gitignore` to isolate directory from parent → child contamination |
| `gsubmod <msg> [dir]` | `gsubmod "Update submodule" ~/Projects/foo` | Commit and push submodule + update parent pointer |
| `gparent <msg> [dir]` | `gparent "Update submodule pointer"` | Commit & push parent repo (submodule pointers) |
| `grepo [commit_msg] [repo_name]` | `grepo "Initial commit"` | Create/init repo, add remote, commit files, setup encryption if needed |

**Requirements:**
- `git` installed and available.
- Directory must be a Git repository (or `grepo` will init it).
- Optional encryption setup via `gencrypt_setup`.

---

## 🔗 Submodule Utilities

| Function | Usage | Description |
|----------|-------|-------------|
| `gsub <folder> [commit_msg] [repo_name]` | `gsub ~/Projects/foo "Add submodule"` | Adds folder as submodule, commits, pushes, handles remote creation |
| `gsub-all [-L N|--level=N] [--debug] <commit_msg>` | `gsub-all "Add all submodules"` | Recursively processes folders to add as submodules |
| `gunsub <submodule>` | `gunsub foo` | Safely removes a submodule and cleans `.git/modules` |
| `gsync-push` | `gsync-push "Sync commit"` | Pushes submodule + parent |
| `gsync-pull` | `gsync-pull` | Pulls latest changes for submodule + parent |
| `gsync` | `gsync` | Full fetch + push for current submodule |
| `gsync-all` | `gsync-all "Update all submodules"` | Recursively push all submodules and parent |

**Requirements:**
- Submodule directories must exist.
- Git repositories must be initialized (`git init`) and remotes configured.
- `$GIT_PROVIDER` and user env vars must be defined.

---

## ⚙️ Ignore Utilities

| Function | Usage | Description |
|----------|-------|-------------|
| `gsub-genignore [dir]` | `gsub-genignore ~/Projects/foo` | Auto-generates `.gsubignore` to exclude unwanted directories from submodule creation |
| `git-genignore [dir]` | `git-genignore ~/Projects/foo` | Generates `.gitignore` with standard patterns for OS, editors, logs, build artifacts, secrets |

**Requirements:**
- Directory must be git-initialized if `.gitignore` is to be committed.

---

## 🔄 Workflow Summary

1. **Set environment variables**:
```zsh
export GIT_PROVIDER="github"
export GITHUB_USER="username"
export GITLAB_USER="username"
```

2. **Initialize repo**
```zsh
grepo "Initial commit"
```

3. **Auto-setup encryption (if sensitive files):**
```zsh
gencrypt_setup . true
```
4. **Add submodules:**
```zsh
gsub folder "Add submodule"
gsub-all "Add all submodules"
```
5. **Sync parent and submodules:**
```zsh
gsync
gsync-all "Update all submodules"
```
6. **Scan for secrets**
```zsh
gsecrets
gshook .
```
7. **Maintain .gitignore and .gsubignore:**
```zsh
git-genignore
gsub-genignore
```
