#!/usr/bin/env bash
#
# ADR-20 tier 1: assert that an acknowledged COMMIT requested a durability
# barrier before it returned. See test/fault/barrier_shim.c for the method and
# what it does not prove.
#
#   scripts/barrier_test.sh            # both tiers; native on Linux, Docker on macOS
#   scripts/barrier_test.sh --tier1    # barriers only (fast)
#   scripts/barrier_test.sh --tier2    # prefix replay only
#   scripts/barrier_test.sh --docker   # force the container
#
# Tier 3, the block-layer check, is not here: it needs root and dm-log-writes,
# which no developer machine reliably has. It runs in CI -- see the
# `durability-block-layer` job and scripts/dm_log_writes_test.sh.
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
IMAGE="${BARRIER_IMAGE:-hexpm/elixir:1.19.1-erlang-28.1.1-ubuntu-noble-20260509.1}"
VOLUME="ash_cell_barrier"

case "${1:-}" in
  --tier1|--tier2) TIER="$1"; shift ;;
esac
case "${2:-}" in
  --tier1|--tier2) TIER="$2" ;;
esac
TIER="${TIER:-}"

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
  # The workspace root is mounted, not just this checkout, because mix.exs uses a
  # path dep on ../ash_sqlite when that directory exists and falls back to git
  # when it does not. Mounting only /app made the container resolve the fork from
  # git and rewrite mix.lock -- which then landed in a commit and conflicted with
  # main. It also meant the durability test ran against the pinned fork rather
  # than the local one, so a fork change could not be tested here at all.
  exec docker run --rm \
    -v "$(cd .. && pwd):/work" \
    -v "$VOLUME:/state" \
    -w "/work/$(basename "$PWD")" \
    -e MIX_ENV=test \
    -e MIX_DEPS_PATH=/state/deps \
    -e MIX_BUILD_PATH=/state/build \
    -e HEX_HOME=/state/hex \
    -e MIX_HOME=/state/mix \
    "$IMAGE" bash scripts/barrier_test.sh --native "${TIER:-}"

# Guard against the lockfile drifting inside the container regardless: it is an
# input to the build, not an output of this test, and a rewritten one has already
# cost one merge conflict.
LOCK_BEFORE=$(git rev-parse HEAD:mix.lock 2>/dev/null || echo none)
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "unsupported platform: $(uname -s)" >&2
  exit 2
fi

export MIX_ENV=test

# git because mix.exs carries a git dependency, gcc to build the shim. Both are
# absent from the hexpm/elixir image, and a missing git fails inside deps.get
# with a message that does not mention the container.
if ! command -v gcc >/dev/null || ! command -v git >/dev/null; then
  echo "==> installing gcc and git"
  apt-get -qq update >/dev/null
  apt-get -qq install -y gcc git >/dev/null 2>&1
fi

WORK="${TMPDIR:-/tmp}/ash_cell_barrier"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> building the shim"
gcc -shared -fPIC -O1 -Wall -o "$WORK/shim.so" test/fault/barrier_shim.c -ldl

echo "==> fetching and compiling deps (cached in the ash_cell_barrier volume)"
mix local.hex --force --if-missing >/dev/null 2>&1 || mix local.hex --force >/dev/null
mix local.rebar --force >/dev/null 2>&1 || true
mix deps.get >/dev/null
mix compile >/dev/null

status=0

if [[ "$TIER" != "--tier2" ]]; then
  echo
  echo "=== Tier 1: was a barrier requested before the acknowledgement? ==="

  for spec in "normal:" "full:" "full:1"; do
    level="${spec%%:*}"
    fullfsync="${spec##*:}"

    run="$WORK/t1_${level}${fullfsync:+_fullfsync}"
    mkdir -p "$run/marks"
    : >"$run/trace.tsv"

    # SHIM_MATCH is the cell directory, so the trace carries the cell's own files
    # and nothing else -- not the BEAM's own I/O, and not the trace file itself.
    # SHIM_DATA is unset here: tier 1 needs the order of operations, not bytes.
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
fi

if [[ "$TIER" != "--tier1" ]]; then
  echo
  echo "=== Tier 2: does every reachable crash state still open? ==="

  for level in normal full; do
    run="$WORK/t2_$level"
    mkdir -p "$run/marks"
    : >"$run/trace.tsv"

    # SHIM_DATA turns on payload capture, which is what makes a replay possible
    # and is why this tier is run separately: the blob is the whole write volume
    # of the workload, and tier 1 has no use for it.
    if ! SHIM_LOG="$run/trace.tsv" \
      SHIM_DATA="$run/data.blob" \
      SHIM_MATCH="$run/cells" \
      SHIM_MARK="$run/marks/" \
      LD_PRELOAD="$WORK/shim.so" \
      PROBE_CELL_DIR="$run/cells" \
      PROBE_WORK="$run" \
      PROBE_SYNC="$level" \
      mix run test/fault/replay_probe.exs; then
      status=1
    fi
  done
fi

if [[ "$LOCK_BEFORE" != "none" ]] && [[ "$(git hash-object mix.lock)" != "$LOCK_BEFORE" ]]; then
  echo
  echo "note: mix.lock was rewritten during this run; restoring it." >&2
  git checkout -- mix.lock
fi

echo
if [[ $status -eq 0 ]]; then
  echo "==> durability invariants hold. Tier 3 (block layer) runs in CI only."
else
  echo "==> FAILED -- see above." >&2
fi

exit $status
