#!/usr/bin/env bash
# Copies this working tree into the control node's repo volume on rpi-01, the
# way scripts/deploy.sh copies salt/ and pillar/ to the Salt master. The local
# tree is the source of truth: --delete removes what was deleted here. Nothing
# is applied; run scripts/ansible.sh afterwards.
set -euo pipefail
host="${ANSIBLE_CONTROLLER_SSH:-root@192.168.23.65}"
dest=/var/lib/containers/storage/volumes/ansible-controller-repo/_data/
cd "$(dirname "$0")/.."
rsync -av --delete \
  --exclude .git --exclude 3pfs --exclude .idea --exclude .DS_Store \
  --exclude config/onepassword.token \
  ./ "$host:$dest"
