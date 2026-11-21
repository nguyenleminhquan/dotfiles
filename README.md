# dotfiles

Personal shell setup for bash and zsh. User-scope install only: everything
lives under `$HOME`, nothing needs sudo.

## Tests

Tests run in throwaway containers on a docker host chosen through the
`DOTFILES_TEST_CONTEXT` environment variable (contexts whose name contains
`prod` are refused). Run them from PowerShell 7:

```powershell
$env:DOTFILES_TEST_CONTEXT = '<context-name>'
pwsh test/run.ps1                    # full matrix
pwsh test/run.ps1 -Only 00-harness   # cases whose name matches a regex
pwsh test/run.ps1 -KeepImages        # keep dotfiles-test:* images afterwards
```

Each `test/cases/<case>.sh` runs once per matrix row and profile and prints a
`row | profile | case | result` table. The exit code is 1 if any row fails.

## Leak guard

This repo is public. Enable the pre-commit hook once per clone:

```sh
git config core.hooksPath .githooks
```

`scripts/check-leaks.sh [files...]` rejects private IPs and common credential
formats. Add company-specific regexes, one per line, to
`~/.config/dotfiles/leak-patterns`; that file is never part of the repo.
