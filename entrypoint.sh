#!/bin/sh
set -eu

# We do this first to ensure sudo works below when renaming the user.
# Otherwise the current container UID may not exist in the passwd database.
eval "$(fixuid -q)"

if [ "${DOCKER_USER-}" ]; then
  USER="$DOCKER_USER"
  if [ -z "$(id -u "$DOCKER_USER" 2>/dev/null)" ]; then
    echo "$DOCKER_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers.d/nopasswd > /dev/null
    # Unfortunately we cannot change $HOME as we cannot move any bind mounts
    # nor can we bind mount $HOME into a new home as that requires a privileged container.
    sudo usermod --login "$DOCKER_USER" coder
    sudo groupmod -n "$DOCKER_USER" coder

    sudo sed -i "/coder/d" /etc/sudoers.d/nopasswd
  fi
fi

# The image runs as uid 1000, so sshd is started through the passwordless sudo
# configured above -- it needs root to read /etc/shadow and bind port 22. It is
# deliberately left in the background: code-server stays PID 1 and a failure
# here only costs SSH, not the whole container.
if [ "${ENABLE_SSH:-1}" = "1" ]; then
  # Give the dev user a password, so an SSH session lands on the same account
  # code-server runs as. DOCKER_USER may have renamed coder above, hence both
  # names -- neither existing is not an error. There is deliberately no
  # equivalent for root: its SSH logins are refused by the image's sshd config.
  if [ "${SSH_USER_PASSWORD-}" ]; then
    for u in coder "${DOCKER_USER-}"; do
      if [ -n "$u" ] && id -u "$u" >/dev/null 2>&1; then
        echo "$u:${SSH_USER_PASSWORD}" | sudo chpasswd
      fi
    done
  fi

  # /run is not part of the image, so the privilege separation directory has to
  # be recreated on every start.
  sudo mkdir -p /run/sshd

  # -E diverts sshd's log to its own file instead of syslog or stderr, so
  # nothing lands in `docker logs`. sshd creates the file itself if a custom
  # SSHD_LOG points somewhere that does not exist yet.
  if ! sudo /usr/sbin/sshd -E "${SSHD_LOG:-/var/log/sshd.log}"; then
    echo "warning: failed to start sshd, continuing without SSH" >&2
  fi
fi

# Allow users to have scripts run on container startup to prepare workspace.
# https://github.com/coder/code-server/issues/5177
if [ -d "${ENTRYPOINTD}" ]; then
  find "${ENTRYPOINTD}" -type f -executable -print -exec {} \;
fi

exec dumb-init /usr/bin/code-server "$@"
