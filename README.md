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
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | bash -s -- --profile server
```

`<owner>/<repo>` is the repository named by `DOTFILES_DEFAULT_REPO` at the top
of `install.sh` (still to be filled in); the piped installer fetches that
repository. `DOTFILES_REPO=<url>` and `DOTFILES_REF=<branch or tag>` choose
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
| `server` | everything in `minimal`, plus zsh-bin (only when the host has no zsh 5.8+), [mise](https://mise.jdx.dev) with exactly pinned tools (kubectl, helm, k9s, argocd, jq, yq, ripgrep, step, sops, ... see `config/mise/config.toml`), starship, network helpers (`port`, `certinfo`, `netshoot`) and zsh completions | at install |
| `workstation` | everything in `server`, plus opentofu, terragrunt, opencode, python 3.12 with a venv in `~/python-env/ansible2.16`, and WSL tweaks (trimmed Windows PATH, sane umask and locale). Default under WSL. | at install |

Going down a profile (for example back to `minimal`) removes the tools a higher
profile installed, and nothing else.

## Using it

```sh
dotfiles update      # fetch the newest code and re-run the installer with the saved profile
dotfiles doctor      # check the install; exit 1 on a FAIL
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
  in `~/.dotfiles-backup/` are always kept, and so is `~/python-env` (the
  workstation's Python environment): purge never removes either.
- Local settings live in files the repo never touches: `~/.bashrc.local`,
  `~/.zshrc.local`, `~/.gitconfig.local` (identity, signing key, credential
  helper) and `~/.config/dotfiles/env.local` (read by every shell, so it must
  never print anything; a `GITHUB_TOKEN` for the installer can go there).
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

## Migration from the old setup

`tools/migrate-from-nobitagamer.sh` moves a machine from the old
`nobitagamer/dotfiles` setup to the `workstation` profile, once. It recognises
the old checkout by its git origin or its `.dots` file and refuses anything
else.

1. Dry run first. It writes nothing and prints the plan: what is backed up, the
   symlinks that point into the old checkout, how much of the zsh history would
   be kept (commands that look like secrets are dropped), which git settings
   move to `~/.gitconfig.local`, and the old mise config against the new one.

   ```sh
   tools/migrate-from-nobitagamer.sh --dry-run
   ```

2. Close every other WSL shell and every VS Code WSL window, then run it for
   real from a checkout of this repository:

   ```sh
   tools/migrate-from-nobitagamer.sh
   ```

   Everything it replaces is copied to `~/.dotfiles-backup/<timestamp>/` first,
   together with `links.tsv` and a `restore.sh`. Open a new terminal afterwards.

3. To roll back, run `dotfiles uninstall`, then
   `bash ~/.dotfiles-backup/<timestamp>/restore.sh`.

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
