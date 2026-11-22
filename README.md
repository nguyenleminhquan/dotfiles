# dotfiles

Shell setup for bash and zsh on Ubuntu 20.04, 22.04 and 24.04, Rocky Linux 9
and WSL1. User scope only: everything lives under `$HOME`, nothing needs sudo,
and the `minimal` profile never touches the network.

## Install

From a clone. Cloning straight into `~/.dotfiles` makes the clone the install
(edits are live, `dotfiles update` pulls):

```sh
git clone <repo-url> ~/.dotfiles
~/.dotfiles/install.sh --profile server
```

or keep the clone anywhere and let the installer mirror it into `~/.dotfiles`
(the links then point into the copy):

```sh
DOTFILES_SRC="$PWD" ./install.sh --profile server
```

With curl:

```sh
curl -fsSL https://raw.githubusercontent.com/nguyenleminhquan/dotfiles/main/install.sh | bash -s -- --profile server
```

The piped installer fetches this repository (`DOTFILES_DEFAULT_REPO` at the
top of `install.sh`). `DOTFILES_REPO=<url>` and `DOTFILES_REF=<branch or tag>` choose
another one.

`--profile` is saved in `~/.config/dotfiles/profile`, so later runs can leave it
out. Without a saved profile it defaults to `workstation` under WSL and is
mandatory everywhere else. Other options: `--dry-run` (change nothing, say what
would happen) and `--no-tools` (link the files, skip every download).

The installer backs up whatever it replaces in `~/.dotfiles-backup/` and ends by
running `dotfiles doctor`. If the doctor reports a FAIL the installer exits
non-zero, after the install itself is complete.

## Profiles

| Profile | Installs | Network |
| --- | --- | --- |
| `minimal` | shell startup files for bash and zsh (silent and safe for `ssh host cmd`), history that keeps secrets out, a kube-aware prompt, screen and micro settings, git settings, the `dotfiles` command. Meant for production hosts. | never |
| `server` | everything in `minimal`, plus zsh-bin (only when the host has no zsh 5.8+), [mise](https://mise.jdx.dev) with exactly pinned tools (kubectl, helm, k9s, argocd, jq, yq, ripgrep, step, sops, ... see `config/mise/config.toml`), starship, zoxide, fzf-tab (fzf for zsh Tab completion), network helpers (`port`, `certinfo`, `netshoot`) and zsh completions | at install |
| `workstation` | everything in `server`, plus opentofu, terragrunt, opencode, python 3.12 with a venv in `~/python-env/ansible2.16`, and WSL tweaks (trimmed Windows PATH, sane umask and locale). Default under WSL. | at install |

Going down a profile (for example back to `minimal`) removes the tools a higher
profile installed, and nothing else.

## Using it

```sh
dotfiles update      # fetch the newest code and re-run the installer with the saved profile
dotfiles doctor      # check the install as a NEW terminal sees it (a login shell with a clean
                     # environment, not this shell's PATH); exit 1 on a FAIL
dotfiles profile     # print the installed profile
dotfiles uninstall   # remove the links, restore the backed up originals
dotfiles uninstall --purge          # also remove the tools and the checkout
dotfiles uninstall --purge --force  # ... even if the checkout holds unsaved work
```

- `update` brings a git clone to its ref (a branch fast-forwards, a tag-pinned
  clone follows the tag), or downloads the repository that was recorded at
  install time. After an install from a local checkout it has no source until
  you give it one: `DOTFILES_SRC=<checkout> dotfiles update`, or install once
  with `DOTFILES_REPO=<url>`.
- `--purge` refuses to delete a checkout that is a git clone with uncommitted
  changes, or with commits that exist on no remote and no tag. It says why and
  changes nothing; commit and push, or add `--force` to delete anyway. Backups
  in `~/.dotfiles-backup/` are always kept, and so are `~/python-env` (the
  workstation's Python environment) and `~/.local/share/zoxide` (the zoxide
  database, which belongs to you like the shell history): neither uninstall nor
  purge removes them.
- On `server` and `workstation`: `z <dir>` jumps to a directory you visited before
  and `zi` picks one with fzf ([zoxide](https://github.com/ajeetdsouza/zoxide); `cd`
  is unchanged). In zsh, Tab completion is [fzf-tab](https://github.com/Aloxaf/fzf-tab)
  (vendored; `**<Tab>` still opens fzf's own path completion). `minimal` keeps
  plain zsh completion and has neither.
- `k` is `kubectl` and completes like it (zsh: after the kubectl completion exists;
  bash: when `__start_kubectl` is loaded). The install also generates zsh
  completions for kubectl, helm, k9s, argocd, talosctl, task, mise and, when the
  host has them, docker, crictl, podman and gh. Put your own `alias k=...` in
  `~/.zshrc.local` or `~/.bashrc.local` and it wins.
- Local settings live in files the repo never touches (see
  [Local layer](#local-layer)): `~/.bashrc.local`, `~/.zshrc.local`,
  `~/.gitconfig.local` and `~/.config/dotfiles/env.local`.
- `~/.config/git/config` is generated and includes the repo's git settings, so
  `git config --global` writes into your file, not into the repo.
  `~/.config/micro/settings.json` is copied once and is yours from then on.
  mise reads our tool list as a fragment (`~/.config/mise/conf.d/dotfiles.toml`);
  `mise use -g` and `mise set -g` write to your own `~/.config/mise/config.toml`.
- With a mirror install (`DOTFILES_SRC`, tarball) the files behind the links are
  copies that the next update replaces: an edit made through a link is lost.
  Edit the source checkout instead.
- If `~/.zshrc` is broken and every login lands in a failing zsh, bash is still
  reachable: `ssh host touch ~/.no-zsh` makes interactive bash stay bash (remove
  the file to switch back).
- Non-interactive shells never print anything and never switch to zsh; they see
  `~/.local/bin` and the mise shims only at the end of `PATH`.

## Local layer

Anything that depends on the machine or holds a secret goes into these files.
They are never committed, and install, update and uninstall never overwrite them.

| File | Read by | Put here |
| --- | --- | --- |
| `~/.config/dotfiles/env.local` | every shell, including `ssh host cmd`, cron and scripts, so it must never print anything | environment for all of them: `GNUPGHOME`, a `GITHUB_TOKEN` for the installer, proxies, `SSL_CERT_FILE` |
| `~/.zshrc.local`, `~/.bashrc.local` | interactive shells only | aliases, completions, key bindings, agents (`eval "$(gpg-agent ...)"`) |
| `~/.gitconfig.local` | git | identity, signing key, credential helper, `safe.directory` |

`env.local` can also hold marked blocks written by the migration (the
`GNUPGHOME` export, and the linuxbrew block below). Each is delimited by
`# >>> ... >>>` and `# <<< ... <<<` lines; delete the whole block to remove it.

Linuxbrew on PATH, when a host still needs it (the block the migration adds):

```sh
# >>> dotfiles: linuxbrew on PATH >>>
# The login shell and tools such as screen live only in linuxbrew on this host.
# Appended last, so system tools win; remove this block once brew is gone.
case ":$PATH:" in
  *:/home/linuxbrew/.linuxbrew/bin:*) ;;
  *) [ -d /home/linuxbrew/.linuxbrew/bin ] && PATH="$PATH:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin" ;;
esac
# <<< dotfiles: linuxbrew on PATH <<<
```

`dotfiles doctor` recognises it (`OK PATH: linuxbrew on PATH (appended last) through
env.local`); linuxbrew on PATH from anywhere else, or in front of `/usr/bin`, is a `WARN`.

Two rules of thumb. Per-project environment (`KUBECONFIG`, `HELMFILE_ENVIRONMENT`,
...) belongs in the project's `mise.toml` under `[env]`, not in a home-wide rc
file. Tokens do not belong in rc files at all: prefer the tool's own login
(for example `argocd login --sso`).

## Migration from the old setup

`tools/migrate-from-nobitagamer.sh` moves a machine from the old
`nobitagamer/dotfiles` setup to this one, once. It recognises the old checkout
by its git origin or its `.dots` file and refuses anything else. `--profile
minimal|server|workstation` picks what gets installed; it defaults to
`workstation` under WSL and is mandatory on any other host (a server must not
get the workstation tools), and a missing one is refused before anything is
changed. `--keep-linuxbrew` always keeps linuxbrew on `PATH`, `--drop-linuxbrew`
never does (the two exclude each other; see the Linuxbrew item below).

1. Dry run first. It writes nothing and prints the plan: what is backed up, the
   symlinks that point into the old checkout, how much of the zsh history would
   be kept (commands that look like secrets are dropped), which git settings
   move to `~/.gitconfig.local`, what happens to the old local layer (below),
   and the old mise config against the new one (`workstation` and `server`
   only: `minimal` installs no tools).

   ```sh
   tools/migrate-from-nobitagamer.sh --dry-run
   ```

2. Close every other WSL shell and every VS Code WSL window, then run it for
   real from a checkout of this repository:

   ```sh
   tools/migrate-from-nobitagamer.sh                   # WSL: workstation
   tools/migrate-from-nobitagamer.sh --profile server  # any other host
   ```

   Everything it replaces is copied to `~/.dotfiles-backup/<timestamp>/` first,
   together with `links.tsv` and a `restore.sh`. Open a new terminal afterwards.

3. To roll back, run `dotfiles uninstall`, then
   `bash ~/.dotfiles-backup/<timestamp>/restore.sh`.

What happens to the old local layer:

- **`~/.localrc`.** The old setup created it on the first install and sourced it
  from login bash and interactive zsh. When it exists, a marked block that
  sources it is added to `~/.zshrc.local` and `~/.bashrc.local` (created if
  missing, appended once otherwise; a symlinked target is refused, move it
  away first), so interactive shells keep reading it.
  `~/.localrc` itself is never touched. Over time, move its entries to the
  file that fits ([Local layer](#local-layer)) and drop the block.
- **`GNUPGHOME`.** When the old shells export it as a plain path (`$HOME/...`,
  `~/...`, `$XDG_CONFIG_HOME/...`) and that directory holds keys, a marked
  `export GNUPGHOME="$HOME/..."` goes into `~/.config/dotfiles/env.local`.
  Without it gpg would look in `~/.gnupg` and find no keys.
- **Linuxbrew.** When the old shells load it (`brew shellenv` or a `PATH` assignment naming
  it) and its `bin` exists, the migration lists the commands that exist only there: the
  login shell when it lives under the brew prefix, the doctor's packages (`git screen curl
  ssh openssl ping`), `zsh`, `micro` and `nano`, minus what a system `PATH`
  (`/usr/local/bin:/usr/bin:/bin`) already has and what the chosen profile provides (the
  tools in `config/mise/commands.*`; `zsh` through zsh-bin on `server` and `workstation`).
  If the list is not empty, the marked block of [Local layer](#local-layer) goes into
  `~/.config/dotfiles/env.local` (same rules as `GNUPGHOME`: created, or appended once, or
  left alone when already there), so those commands stay reachable and system tools still
  win. The same happens when something install.sh needs (`curl`, `tar`, `git` for the
  profile or `DOTFILES_REPO`) exists only in brew, and when the block is in `env.local`
  already. The report says `linuxbrew: kept on PATH (appended last) — only there: ...`.
  `--keep-linuxbrew` writes the block even when that list is empty. When brew is not kept
  (nothing depends on it, or `--drop-linuxbrew`) nothing is written, install.sh runs
  without brew on its `PATH`, and the report counts and names every command in the brew
  `bin` directory that a new terminal will lose (the first 15, then `(+N more)`; the login
  shell is named when it lives there and keeps working by its absolute path), ending with
  `use --keep-linuxbrew to keep them on PATH`. With `--drop-linuxbrew` the run is refused,
  before anything is changed, when `curl` or `tar` (server, workstation) exist only in
  brew. Linuxbrew itself is never touched, and `restore.sh` removes the block like any
  other.
- **Report.** The old shell files are scanned (the old checkout only, no walk of
  your home) for files they source or test and for variables that relocate
  state (`GNUPGHOME`, `ZDOTDIR`, `HISTFILE`, `XDG_*_HOME`). Each file that exists
  and each such variable is listed with its fate: `kept`, `carried to
  env.local`, `history migrated to ~/.zsh_history` or `no longer read`. It is
  information only and never stops the migration.
- `restore.sh` removes a file the migration created while it is unchanged, and
  cuts the marked block out of a file that existed before (byte for byte what
  it was). A file or block you edited since is kept, with a warning.

The migration installs from the checkout it runs in, so `dotfiles update` has no
source yet. Set `DOTFILES_REPO=<repo url>` when running the migration (or run
`install.sh` once with it set) and `update` works from then on.

## Tests

Tests run in throwaway containers on a docker host chosen through the
`DOTFILES_TEST_CONTEXT` environment variable (a context whose name contains
`prod` is refused). Run them from PowerShell 7:

```powershell
$env:DOTFILES_TEST_CONTEXT = '<context-name>'
pwsh test/run.ps1                    # full matrix (about half an hour)
pwsh test/run.ps1 -Only 20-install   # cases whose name matches a regex
pwsh test/run.ps1 -KeepImages        # keep dotfiles-test:* images afterwards
```

Each `test/cases/<case>.sh` runs once per matrix row (Ubuntu 20.04 with and
without zsh, 22.04, 24.04 without git, Rocky 9, and a WSL1 stand-in) and profile,
and prints a `row | profile | case | result` table. The exit code is 1 if any row
fails. Set `GITHUB_TOKEN` in the environment to raise the GitHub API limit for
the tool downloads; it is passed into the container and never printed.

`DF_LINUXBREW_PREFIX`, `DF_LOGIN_SHELL` and `DF_ETC_ENVIRONMENT_FILE` are test hooks
(the linuxbrew directory, the login shell, `/etc/environment`) for the migration
and the doctor; their defaults are the real locations and nothing else sets them.

## Leak guard

This repo is public. Enable the pre-commit hook once per clone:

```sh
git config core.hooksPath .githooks
```

`scripts/check-leaks.sh [files...]` rejects private IPs and common credential
formats; the hook also runs it over your commit identity (author and committer),
so a company e-mail address cannot end up in a commit. Add company-specific
regexes, one per line, to `~/.config/dotfiles/leak-patterns`; that file is never
part of the repo. Without it the hook only warns, on every commit.
