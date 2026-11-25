#!/bin/bash
# Starts an ssh-agent and loads the control node's SSH key into it, read from
# 1Password (ANSIBLE_SSH_KEY_REF). The key never touches the disk. Then runs
# the container's command.
#
# The 1Password service account token is read from
# $OP_SERVICE_ACCOUNT_TOKEN_FILE (the podman secret ansible-op-token) and is
# not left in any environment; the op lookup plugin reads the same file.
set -euo pipefail

rm -f "$SSH_AUTH_SOCK"
ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null    # forks; keeps running after exec

if [ -n "${ANSIBLE_SSH_KEY_REF:-}" ]; then
  if [ ! -r "$OP_SERVICE_ACCOUNT_TOKEN_FILE" ]; then
    echo "entrypoint: $OP_SERVICE_ACCOUNT_TOKEN_FILE is missing; create the podman secret ansible-op-token (MIGRATION.md)" >&2
    exit 1
  fi
  # op read ends the key with a newline, which ssh-add needs
  OP_SERVICE_ACCOUNT_TOKEN="$(cat "$OP_SERVICE_ACCOUNT_TOKEN_FILE")" \
    op read "$ANSIBLE_SSH_KEY_REF" | ssh-add -q -
  echo "entrypoint: SSH key loaded: $(ssh-add -l)"
else
  echo "entrypoint: ANSIBLE_SSH_KEY_REF is unset, ssh-agent has no key" >&2
fi

exec "$@"
