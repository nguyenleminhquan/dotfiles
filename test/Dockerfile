# Test image: one base distro plus optional zsh/git, an unprivileged user
# without sudo, and the repo baked in at /src (remote docker contexts cannot
# bind-mount local paths).
ARG BASE=ubuntu:22.04
FROM ${BASE}

ARG WITH_ZSH=1
ARG WITH_GIT=1

# Root-only image preparation; this is the one place sudo-free root is used.
RUN set -eu; \
    extra=""; \
    if [ "$WITH_ZSH" = "1" ]; then extra="$extra zsh"; fi; \
    if [ "$WITH_GIT" = "1" ]; then extra="$extra git"; fi; \
    if command -v apt-get >/dev/null 2>&1; then \
      export DEBIAN_FRONTEND=noninteractive; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        curl ca-certificates bsdutils procps locales $extra; \
      # Debian's locale-gen ignores its arguments and builds what /etc/locale.gen enables.
      if [ -f /etc/locale.gen ]; then sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen; fi; \
      locale-gen en_US.UTF-8; \
      rm -rf /var/lib/apt/lists/*; \
    else \
      dnf install -y \
        curl-minimal ca-certificates util-linux procps-ng glibc-langpack-en $extra; \
      dnf clean all; \
    fi; \
    useradd --create-home --shell /bin/bash tester; \
    printf 'export DF_TEST_PROFILED=from-profile-d\n' >/etc/profile.d/zz-dotfiles-test.sh

ENV LANG=en_US.UTF-8

COPY . /src
RUN chmod -R a+rX /src

USER tester
WORKDIR /home/tester
