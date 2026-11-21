# shellcheck shell=bash
# Aliases and editor choice shared by interactive bash and zsh. The git
# aliases live in config/git/config instead, so `git s` works everywhere.

alias k=kubectl
alias t=task
alias ll='ls -alhF --color=auto'

# micro when it is installed, then nano, then vi (which every host has).
if command -v micro >/dev/null 2>&1; then
  EDITOR="micro"
elif command -v nano >/dev/null 2>&1; then
  EDITOR="nano"
else
  EDITOR="vi"
fi
VISUAL="$EDITOR"
export EDITOR VISUAL
