# Vendored third-party code

Committed so that the `minimal` profile (and any host without network access)
never has to download anything at install or run time.

## zsh-autosuggestions

- Upstream: https://github.com/zsh-users/zsh-autosuggestions
- Tag: `v0.7.1`
- Commit: `e52ee8ca55bcc56a17c828767a3f98f22a68d4eb`
- License: MIT (see `zsh-autosuggestions/LICENSE`)
- Files kept: `zsh-autosuggestions.zsh` (the built plugin), `zsh-autosuggestions.plugin.zsh`,
  `LICENSE`, `README.md`. Sources, specs and CI files are left out.

To update, check out the new tag upstream, copy the same four files, and
change the tag and commit above.

## fzf-tab

- Upstream: https://github.com/Aloxaf/fzf-tab
- Tag: `v1.3.0`
- Commit: `d7e0234614dbe5369fdd760907d12c0e05a4dccc`
- License: MIT (see `fzf-tab/LICENSE`; `fzf-tab/lib/zsh-ls-colors/LICENSE` covers the
  bundled ls-colors parser)
- Files kept: `fzf-tab.plugin.zsh`, `fzf-tab.zsh`, `LICENSE`, `README.md`, and in `lib/`
  the autoloaded helpers (`-ftb-colorize`, `-ftb-fzf`, `-ftb-generate-complist`,
  `-ftb-generate-header`, `-ftb-generate-query`, `-ftb-preview.tpl`, `-ftb-version`,
  `ftb-switch-group`, `ftb-tmux-popup`) and `zsh-ls-colors/` (`ls-colors.zsh`, `LICENSE`,
  `README.md`).
  Left out: the optional compiled module (`modules/`, `lib/-ftb-build-module`, so
  `build-fzf-tab-module` does nothing here and the pure-zsh path is always used), the tests,
  the CI files and the demo.
- Loaded by `shell/zshrc` on the `server` and `workstation` profiles only, after `compinit`
  and before zsh-autosuggestions.

To update, check out the new tag upstream, copy the same files, and change the tag and
commit above.
