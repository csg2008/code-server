# syntax=docker/dockerfile:experimental

ARG BASE=ubuntu:26.04
FROM scratch AS packages
COPY release-packages/code-server*.deb /tmp/

FROM $BASE

# policy-rc.d tells invoke-rc.d to leave services alone. Without it, installing
# openssh-server makes the postinst try to start sshd during the build, which is
# both pointless and a source of build failures in a container without systemd.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
  && chmod +x /usr/sbin/policy-rc.d \
  && apt-get update \
  && apt-get install -y \
    curl \
    dumb-init \
    git \
    git-lfs \
    htop \
    locales \
    lsb-release \
    man-db \
    nano \
    openssh-client \
    openssh-server \
    procps \
    sudo \
    vim-tiny \
    wget \
    zsh \
  && rm -f /usr/sbin/policy-rc.d \
  && git lfs install \
  && rm -rf /var/lib/apt/lists/*

# https://wiki.debian.org/Locale#Manually
RUN sed -i "s/# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen \
  && locale-gen
ENV LANG=en_US.UTF-8

# Ubuntu 26.04 ships systemd's OSC 3008 shell integration, which a login shell
# sources out of profile.d. It emits a context escape sequence at every prompt;
# terminals without OSC 3008 support -- i.e. most SSH clients -- print it as
# literal text in front of the prompt. Drop the hook and mask the tmpfiles rule
# that would recreate it, which is the disable method documented in the script
# itself. Nothing else in the image depends on it.
RUN rm -f /etc/profile.d/80-systemd-osc-context.sh \
  && ln -sf /dev/null /etc/tmpfiles.d/20-systemd-osc-context.conf

# SSH login policy. Settings go into a drop-in rather than a sed against
# sshd_config: the shipped PermitRootLogin line is commented out and its exact
# wording is not stable across OpenSSH releases. Include directives are read
# first, so this wins over the defaults further down the file.
#
# Root cannot log in over SSH -- log in as coder and use its passwordless sudo.
# passwd -l keeps the root account passwordless as well, so the setting cannot
# be undone by a stray edit to PermitRootLogin alone.
RUN mkdir -p /etc/ssh/sshd_config.d \
  && printf 'PermitRootLogin no\nPasswordAuthentication yes\n' \
       > /etc/ssh/sshd_config.d/99-code-server.conf \
  && passwd -l root \
  && touch /var/log/sshd.log \
  && chmod 644 /var/log/sshd.log

# ssh-keygen -A creates any missing host keys, so the image is usable without a
# first-run step.
RUN ssh-keygen -A

# CODER_PASSWORD is baked in because this image targets a trusted internal
# network; SSH_USER_PASSWORD can override it at runtime. adduser creates the
# account with a locked password, so chpasswd is what actually enables login.
ARG CODER_PASSWORD=coder
RUN if grep -q 1000 /etc/passwd; then \
    userdel -r "$(id -un 1000)"; \
  fi \
  && adduser --gecos '' --disabled-password coder \
  && echo "coder:$CODER_PASSWORD" | chpasswd \
  && echo "coder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/nopasswd

RUN ARCH="$(dpkg --print-architecture)" \
  && curl -fsSL "https://github.com/boxboat/fixuid/releases/download/v0.6.0/fixuid-0.6.0-linux-$ARCH.tar.gz" | tar -C /usr/local/bin -xzf - \
  && chown root:root /usr/local/bin/fixuid \
  && chmod 4755 /usr/local/bin/fixuid \
  && mkdir -p /etc/fixuid \
  && printf "user: coder\ngroup: coder\n" > /etc/fixuid/config.yml

# The exec bit is set here rather than relied upon from the build context:
# checkouts on Windows (and git repos that do not store the mode) copy the
# script in as 0644, which makes the ENTRYPOINT fail with "permission denied".
COPY entrypoint.sh /usr/bin/entrypoint.sh
RUN chmod +x /usr/bin/entrypoint.sh

RUN --mount=from=packages,src=/tmp,dst=/tmp/packages dpkg -i /tmp/packages/code-server*$(dpkg --print-architecture).deb

# Allow users to have scripts run on container startup to prepare workspace.
# https://github.com/coder/code-server/issues/5177
ENV ENTRYPOINTD=${HOME}/entrypoint.d

# sshd is started by the entrypoint unless ENABLE_SSH is set to 0.
# SSH_USER_PASSWORD overrides coder's password at runtime; without it the
# build-time CODER_PASSWORD is kept.
ENV ENABLE_SSH=1

# sshd logs here rather than to syslog or stderr, so it can be read with
# `docker exec ... cat /var/log/sshd.log`. Point it at a bind mount if the logs
# need to outlive the container.
ENV SSHD_LOG=/var/log/sshd.log

# 8080: code-server, 22: sshd.
EXPOSE 22 8080
# This way, if someone sets $DOCKER_USER, docker-exec will still work as
# the uid will remain the same. note: only relevant if -u isn't passed to
# docker-run.
USER 1000
ENV USER=coder
WORKDIR /home/coder
ENTRYPOINT ["/usr/bin/entrypoint.sh", "--bind-addr", "0.0.0.0:8080", "."]
