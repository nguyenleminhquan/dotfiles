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
