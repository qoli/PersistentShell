#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image_name=persistent-shell-remote-openssh-acceptance
container_name=persistent-shell-remote-openssh-acceptance-$$

cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker build \
  --file "$repository_root/Tests/Dockerfile.remote-openssh-acceptance" \
  --tag "$image_name" \
  "$repository_root"

docker run --detach \
  --name "$container_name" \
  --publish 127.0.0.1::22 \
  "$image_name" >/dev/null

published_port=$(docker port "$container_name" 22/tcp | sed 's/.*://')

PERSISTENT_SHELL_RUN_LOCALHOST_TEST=1 \
PERSISTENT_SHELL_OPENSSH_HOST=127.0.0.1 \
PERSISTENT_SHELL_OPENSSH_PORT="$published_port" \
PERSISTENT_SHELL_OPENSSH_USER=root \
PERSISTENT_SHELL_OPENSSH_PASSWORD=persistent-shell-acceptance \
swift test --package-path "$repository_root" \
  --filter RealOpenSSHTests/testOptInLocalhostOpenSSH
