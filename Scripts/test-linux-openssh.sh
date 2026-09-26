#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image_name=persistent-shell-openssh-acceptance
container_name=persistent-shell-openssh-acceptance-$$

cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker build \
  --file "$repository_root/Tests/Dockerfile.openssh-acceptance" \
  --tag "$image_name" \
  "$repository_root"

docker run --detach \
  --name "$container_name" \
  --publish 127.0.0.1::22 \
  --volume "$repository_root:/workspace:ro" \
  "$image_name" >/dev/null

published_port=$(docker port "$container_name" 22/tcp | sed 's/.*://')

docker exec \
  --env PERSISTENT_SHELL_RUN_LOCALHOST_TEST=1 \
  --env PERSISTENT_SHELL_OPENSSH_HOST=127.0.0.1 \
  --env PERSISTENT_SHELL_OPENSSH_PORT=22 \
  --env PERSISTENT_SHELL_OPENSSH_USER=root \
  --env PERSISTENT_SHELL_OPENSSH_PASSWORD=persistent-shell-acceptance \
  "$container_name" \
  swift test --package-path /workspace --scratch-path /tmp/persistent-shell-build \
    --filter RealOpenSSHTests/testOptInLocalhostOpenSSH
