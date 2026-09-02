#!/usr/bin/env bash
# Docker wrapper for scripts/fs_in_cell_bench.sh.
#
# macOS has no FUSE without a kernel extension, and Linux is the deployment
# target anyway, so the benchmark runs in a Linux VM. `colima start` first.
#
#     ./scripts/fs_in_cell_bench_run.sh
#
# --privileged is for /dev/fuse and for dropping the page cache between phases;
# without the second one, `stat` and `read` measure the kernel's dentry cache
# rather than the filesystem underneath it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$here/fs_in_cell_fuse
image=fs-in-cell-bench

docker build -t "$image" -f - "$here" <<'DOCKERFILE'
FROM node:22-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends fuse3 sqlite3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

exec docker run --rm --privileged \
  -v "$src":/src \
  -v "$here/fs_in_cell_bench.sh":/bench.sh:ro \
  -e DAEMON=/src/target/release/fs_in_cell_fuse \
  "$image" bash /bench.sh
