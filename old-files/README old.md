# 🧩 git-utils

> ⚙️ Minimalist Git automation toolkit for managing monorepo + submodule workflows in `.config` setups. Built for speed, clarity, and modular GitHub syncing.

---

## 📁 Overview

This utility is designed for `~/.config`-based dotfile repositories where each folder (like `zsh`, `brew`, `prompt`, etc.) is independently versioned via **Git submodules** and linked to its own **GitHub repo**.

The goal is to:
- Initialise, push, and link new config folders easily
- Add them as GitHub submodules with one command
- Maintain parent repo’s pointer
- Provide status-aware sync commands

---

## 🚀 Commands

### `grepo [repo_name] [commit_msg]`
Create and push a new Git repo to GitHub from the current folder.
🔧 If remote doesn’t exist, it’s created via GitHub CLI.

**Example**:
```bash
cd ~/.config/zsh
grepo zsh-config "Initial commit"
```

---

### `gsub <folder> [commit_msg] [repo_name]`
Initialise a folder as a submodule, push it to GitHub, and update parent repo pointer.

**Example**:
```bash
cd ~/.config
gsub brew "Add Homebrew config" brew-config
```

---

### `gunsub <folder>`
Fully removes a submodule and cleans references.

**Example**:
```bash
cd ~/.config
gunsub prompt
```

---

### `git_submodule [msg]`
Commits & pushes submodule changes from current folder.

---

### `git_parentmodule [msg]`
Commits & pushes parent repo to reflect updated submodule pointers.

---

## 🔄 gsync Commands

| Command         | Description                                            |
|----------------|--------------------------------------------------------|
| `gsync-status`  | Shows ahead/behind status                             |
| `gsync`         | `fetch → status → push` (submodule + parent)          |
| `gsync-push`    | Commit & push both submodule and parent               |
| `gsync-pull`    | Pull submodule and then parent                        |
| `gsync-all`     | Run `git_submodule` on all submodules + parent        |

---

## 🔤 Tab Completion (Zsh)

If you have completions enabled, drop `_gutils` into `~/.config/zsh/completions/`:

```bash
# ~/.config/zsh/completions/_gutils
#compdef gsub grepo gsync gsync-push gsync-pull gsync-all gunsub

_arguments -s \
  '1: :->cmds' \
  '*:: :->args'
...
```

Then load it via your plugin system:

```zsh
zsh_add_completion "~/.config/zsh/completions/_gutils"
```

---

## 🔐 GitHub CLI (Required)

These commands depend on [`gh`](https://cli.github.com/). Install it via:

```bash
brew install gh
gh auth login
```

---

## 📦 Example Workflow

```bash
cd ~/.config/zsh/prompt
grepo prompt-zsh "Initial commit"
cd ~/.config/zsh
gsub prompt "Add prompt config" prompt-zsh
gsync-all "Update config with new submodules"
```

---

## 📁 Directory Structure (Recommended)

```bash
.config/
├── zsh/                   → github.com/smnuman/zsh-config
│   └── prompt/            → github.com/smnuman/prompt-zsh
├── brew/                  → github.com/smnuman/brew-config
└── dotconfig-zsh/         → parent repo hosting all submodules
```

*Note: `prompt/` is a subfolder under `zsh/`.*

---

## 🧠 Author & License

Built by [@smnuman](https://github.com/smnuman)
MIT License – use, modify, share freely
