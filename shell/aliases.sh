# shellcheck shell=bash
# Aliases and editor choice shared by interactive bash and zsh. The git
# aliases live in config/git/config instead, so `git s` works everywhere.

alias k=kubectl
alias t=task
alias ll='ls -alhF --color=auto'

# Colours that the Debian and Ubuntu skeleton ~/.bashrc gave ls and grep (on
# RHEL, /etc/profile.d does the same). With no LS_COLORS, GNU ls uses its
# built-in colours, so dircolors runs only for a ~/.dircolors of the user's.
if [ -r "$HOME/.dircolors" ] && command -v dircolors >/dev/null 2>&1; then
  eval "$(dircolors -b "$HOME/.dircolors")"
fi
alias ls='ls --color=auto'
alias grep='grep --color=auto'

# lesspipe lets less show archives and other non-text files: the variables
# Ubuntu's skeleton sets with `eval "$(lesspipe)"`, without running it.
if [ -z "${LESSOPEN:-}" ] && [ -x /usr/bin/lesspipe ]; then
  export LESSOPEN='| /usr/bin/lesspipe %s' LESSCLOSE='/usr/bin/lesspipe %s %s'
fi

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
