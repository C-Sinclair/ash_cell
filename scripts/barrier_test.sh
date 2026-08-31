#!/usr/bin/env bash
#
# ADR-20 tier 1: assert that an acknowledged COMMIT requested a durability
# barrier before it returned. See test/fault/barrier_shim.c for the method and
# what it does not prove.
#
#   scripts/barrier_test.sh            # native on Linux, re-execs in Docker on macOS
#   scripts/barrier_test.sh --docker   # force the container
#
# Linux only, because it needs LD_PRELOAD to reach beam.smp: macOS strips
# DYLD_INSERT_LIBRARIES under SIP before the BEAM ever starts. On a Mac this
# re-execs itself inside a container, keeping its deps and build artefacts in
# tmp/ so they never collide with the host's -- a macOS _build cannot be reused
# by a Linux BEAM.

set -euo pipefail

cd "$(dirname "$0")/.."

# Overridable, because a pinned hexpm/elixir tag carries a build date and goes
# stale. `docker pull` failing with a clear message beats the container starting
# and `mix` not being on the PATH.
IMAGE="${BARRIER_IMAGE:-hexpm/elixir:1.19.1-erlang-28.1.1-ubuntu-noble-20250908}"
VOLUME="ash_cell_barrier"

if [[ "${1:-}" == "--docker" ]] || { [[ "${1:-}" != "--native" ]] && [[ "$(uname -s)" == "Darwin" ]]; }; then
  if ! command -v docker >/dev/null; then
    echo "This test needs Linux. On macOS it runs in Docker, which is not installed." >&2
    exit 2
  fi

  if ! docker info >/dev/null 2>&1 || [[ -z "$(docker info --format '{{.ServerVersion}}' 2>/dev/null)" ]]; then
    echo "The Docker daemon is not answering. Restart Docker Desktop and try again." >&2
    exit 2
  fi

  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> pulling $IMAGE"
    if ! docker pull -q "$IMAGE"; then
      echo >&2
      echo "Could not pull $IMAGE. hexpm/elixir tags carry a build date, so this one" >&2
      echo "may have been superseded. Pick a current tag for the versions in" >&2
      echo ".tool-versions from https://hub.docker.com/r/hexpm/elixir/tags and set:" >&2
      echo "  BARRIER_IMAGE=hexpm/elixir:<tag> scripts/barrier_test.sh" >&2
      exit 2
    fi
  fi

  echo "==> macOS: re-running inside $IMAGE"

  # Deps and build artefacts go in a named volume rather than under the repo. A
  # macOS _build cannot be reused by a Linux BEAM anyway, and compiling onto a
  # bind mount is slow enough on Docker Desktop to look like a hang -- the first
  # attempt at this wedged the daemon. The source is mounted read-write only
  # because `mix deps.get` may rewrite mix.lock; nothing else in here writes to
  # the repo, and the artefacts all land in the volume or in /tmp.
  exec docker run --rm \
    -v "$PWD:/app" \
    -v "$VOLUME:/state" \
    -w /app \
    -e MIX_ENV=test \
    -e MIX_DEPS_PATH=/state/deps \
    -e MIX_BUILD_PATH=/state/build \
    -e HEX_HOME=/state/hex \
    -e MIX_HOME=/state/mix \
    "$IMAGE" bash scripts/barrier_test.sh --native
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "unsupported platform: $(uname -s)" >&2
  exit 2
fi

export MIX_ENV=test

if ! command -v gcc >/dev/null; then
  echo "==> installing gcc"
  apt-get -qq update >/dev/null
  apt-get -qq install -y gcc >/dev/null
fi

WORK="${TMPDIR:-/tmp}/ash_cell_barrier"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> building the shim"
gcc -shared -fPIC -O1 -Wall -o "$WORK/shim.so" test/fault/barrier_shim.c -ldl

echo "==> fetching and compiling deps (cached in tmp/barrier)"
mix local.hex --force --if-missing >/dev/null 2>&1 || mix local.hex --force >/dev/null
mix local.rebar --force >/dev/null 2>&1 || true
mix deps.get >/dev/null
mix compile >/dev/null

status=0

for spec in "normal:" "full:" "full:1"; do
  level="${spec%%:*}"
  fullfsync="${spec##*:}"

  run="$WORK/${level}${fullfsync:+_fullfsync}"
  mkdir -p "$run/marks"
  : >"$run/trace.tsv"

  # SHIM_MATCH is the cell directory, so the trace carries the cell's own files
  # and nothing else -- not the BEAM's own I/O, and not the trace file itself.
  if ! SHIM_LOG="$run/trace.tsv" \
    SHIM_MATCH="$run/cells" \
    SHIM_MARK="$run/marks/" \
    LD_PRELOAD="$WORK/shim.so" \
    PROBE_CELL_DIR="$run/cells" \
    PROBE_SYNC="$level" \
    PROBE_FULLFSYNC="$fullfsync" \
    mix run test/fault/barrier_probe.exs; then
    status=1
  fi

  echo "    trace: $run/trace.tsv ($(wc -l <"$run/trace.tsv") records)"
done

echo
if [[ $status -eq 0 ]]; then
  echo "==> barrier invariant holds under :full, and is absent under :normal, as ADR-20 records."
else
  echo "==> FAILED -- see above." >&2
fi

exit $status
