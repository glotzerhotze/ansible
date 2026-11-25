#!/usr/bin/env bash
# Runs Ansible in the control-node container on rpi-01.
#
#   scripts/ansible.sh site.yml --check --diff            # dry run, all hosts
#   scripts/ansible.sh site.yml --tags quadlets --limit rpi-02
#   scripts/ansible.sh ansible all -m ping                # any other command
#
# Run scripts/ansible-sync.sh first to copy your changes over.
set -euo pipefail
host="${ANSIBLE_CONTROLLER_SSH:-root@192.168.23.65}"
container="${ANSIBLE_CONTROLLER_CONTAINER:-ansible-controller}"
if [[ "${1:-}" == *.yml ]]; then
  set -- ansible-playbook "$@"
fi
# shellcheck disable=SC2029  # the arguments are meant to be expanded here
exec ssh -t "$host" "podman exec -it $container $(printf '%q ' "$@")"
