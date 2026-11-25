#!/usr/bin/env bash
# Builds the control-node image and pushes it to the registry, like the
# salt-master image. rpi-01 runs it, so the default platform is arm64.
#
#   control-node/build.sh 2.22.0-1          # <ansible-core version>-<build>
#   PLATFORMS=linux/arm64,linux/amd64 control-node/build.sh 2.22.0-1
#
# Then raise ansible_controller_version in inventory/host_vars/rpi-01/quadlets.yml.
set -euo pipefail
tag="${1:?usage: $0 <tag>, e.g. 2.22.0-1}"
image="${IMAGE:-hub.klessen.cloud/glotzerhotze/ansible-controller}:$tag"
platforms="${PLATFORMS:-linux/arm64}"
cd "$(dirname "$0")"
podman manifest rm "$image" >/dev/null 2>&1 || true
podman build --platform "$platforms" --manifest "$image" -f Containerfile .
podman manifest push --all "$image" "docker://$image"
