#!/usr/bin/env bash
# Docker wrapper for smoke.sh: builds the daemon, then runs the smoke test against it
# inside a privileged Linux container with /dev/fuse, once per mode.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
image=fs-in-cell-smoke

docker build -t "$image" -f - "$here" <<'DOCKERFILE'
FROM node:22-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends fuse3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

docker run --rm -v cargoreg:/usr/local/cargo/registry -v "$here":/src -w /src rust:1-bookworm \
  sh -c 'apt-get update -qq && apt-get install -y -qq libfuse3-dev pkg-config && cargo build --release'

for mode in inline cas; do
  echo "=== smoke test: mode=$mode ==="
  # --device /dev/fuse --cap-add SYS_ADMIN was not enough under colima's default
  # seccomp/apparmor profile (fusermount3 got EPERM on mount(2)); --privileged is.
  docker run --rm --privileged \
    -v "$here":/src -w /src \
    -e MODE="$mode" \
    "$image" bash smoke.sh
done
