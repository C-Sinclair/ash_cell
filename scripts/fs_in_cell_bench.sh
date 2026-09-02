#!/usr/bin/env bash
# Benchmark: a real POSIX filesystem stored in a cell, through FUSE.
#
# The follow-up to scripts/fs_in_cell_probe.exs, which measured the storage layer
# with an in-process caller and could not measure the kernel round trip. This
# mounts the same two schemas through FUSE and runs a real workload over them.
#
#   native   the container's own filesystem -- the thing being replaced
#   inline   one row per file, bytes in the row
#   cas      inodes + content-addressed blobs, so a fork shares content
#
# Workloads:
#
#   npm      npm install of a real dependency tree   -- the acceptance test
#   clone    untar a source tree                     -- checking a repo out
#   stat     stat every file                         -- what a build's path
#                                                       resolution costs
#   read     cat every file                          -- a build reading sources
#   fork     produce a divergent copy, and its bytes -- the product
#
# Runs inside Linux. See scripts/fs_in_cell_bench_run.sh for the docker wrapper.
set -euo pipefail

DAEMON=${DAEMON:-/src/target/release/fs_in_cell_fuse}
WORK=${WORK:-/work}
RESULTS=$WORK/results.txt

mkdir -p "$WORK"
: > "$RESULTS"

log() { printf '%s\n' "$*" | tee -a "$RESULTS"; }

ms() { echo $(( ($2 - $1) / 1000000 )); }
now() { date +%s%N; }

# A source tree with the shape that matters: mostly small files, deep-ish paths,
# a long tail of larger ones. Built once, on native, and untarred into each
# backend so every one is handed identical bytes.
make_tree() {
  local src=$WORK/tree
  [ -d "$src" ] && return
  mkdir -p "$src"
  for i in $(seq 1 4000); do
    d="$src/pkg/$(printf '%03d' $((i % 200)))/sub$((i / 200 % 8))"
    mkdir -p "$d"
    if [ $((i % 40)) -eq 0 ]; then head -c 98304 /dev/urandom; else head -c 2048 /dev/urandom; fi > "$d/mod_$i.ex"
  done
  tar cf "$WORK/tree.tar" -C "$src" .
}

# Warm the npm cache before any backend runs. Otherwise the first backend
# measured pays for every tarball download and the rest install from cache, and
# the comparison is between network conditions rather than filesystems.
prime_npm_cache() {
  local d=$WORK/prime
  rm -rf "$d"; mkdir -p "$d"
  cp "$WORK/pkgsrc/package.json" "$d/"
  (cd "$d" && npm install --no-audit --no-fund --loglevel=error > "$WORK/npm-prime.log" 2>&1)
  rm -rf "$d"
}

# A dependency tree big enough that npm does real work -- many small files, many
# directories, symlinks in .bin, and a lot of rename() traffic.
make_pkg() {
  mkdir -p "$WORK/pkgsrc"
  cat > "$WORK/pkgsrc/package.json" <<'JSON'
{
  "name": "fs-in-cell-probe",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "express": "4.19.2",
    "typescript": "5.4.5",
    "eslint": "8.57.0"
  }
}
JSON
}

mount_backend() {
  local mode=$1 mnt=$2 db=$3
  mkdir -p "$mnt"
  "$DAEMON" --db "$db" --mode "$mode" --mount "$mnt" &
  echo $! > "$WORK/daemon.pid"
  for _ in $(seq 1 100); do
    mountpoint -q "$mnt" && return 0
    sleep 0.1
  done
  echo "FAILED to mount $mode" >&2
  return 1
}

unmount_backend() {
  local mnt=$1
  fusermount3 -u "$mnt" 2>/dev/null || fusermount -u "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
  [ -f "$WORK/daemon.pid" ] && wait "$(cat "$WORK/daemon.pid")" 2>/dev/null || true
  rm -f "$WORK/daemon.pid"
}

bytes_of() {
  if [ -d "$1" ]; then du -sb "$1" | cut -f1; else stat -c %s "$1" 2>/dev/null || echo 0; fi
}

run_backend() {
  local name=$1 root=$2

  local t0 t1
  t0=$(now); tar xf "$WORK/tree.tar" -C "$root"; sync; t1=$(now)
  local clone; clone=$(ms "$t0" "$t1")

  # Drop what the kernel cached during the untar, or `stat` measures the dentry
  # cache and not the filesystem.
  drop_caches

  t0=$(now); find "$root" -type f -exec stat -c %s {} + > /dev/null; t1=$(now)
  local stat_ms; stat_ms=$(ms "$t0" "$t1")

  drop_caches

  t0=$(now); find "$root" -type f -print0 | xargs -0 cat > /dev/null; t1=$(now)
  local read_ms; read_ms=$(ms "$t0" "$t1")

  rm -rf "${root:?}/pkg"

  cp "$WORK/pkgsrc/package.json" "$root/package.json"
  t0=$(now)
  local npm_ms npm_status
  if (cd "$root" && npm install --no-audit --no-fund --loglevel=error > "$WORK/npm-$name.log" 2>&1); then
    npm_status=ok
  else
    npm_status=FAILED
  fi
  t1=$(now); npm_ms=$(ms "$t0" "$t1")

  local npm_files
  npm_files=$(find "$root/node_modules" -type f 2>/dev/null | wc -l | tr -d ' ')

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$clone" "$stat_ms" "$read_ms" "$npm_ms" "$npm_status" "$npm_files" \
    >> "$WORK/raw.tsv"
}

drop_caches() {
  sync
  if ! echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then
    echo "WARNING: could not drop the page cache -- stat and read are cache-warm" >&2
  fi
}

main() {
  make_tree
  make_pkg
  prime_npm_cache
  : > "$WORK/raw.tsv"

  log ""
  log "tree: 4000 files, ~17 MB; npm: express + typescript + eslint"
  log ""

  rm -rf "$WORK/native"; mkdir -p "$WORK/native"
  run_backend native "$WORK/native"
  local native_bytes; native_bytes=$(bytes_of "$WORK/native")

  for mode in inline cas; do
    rm -f "$WORK/$mode.db"*
    mount_backend "$mode" "$WORK/mnt-$mode" "$WORK/$mode.db"
    run_backend "$mode" "$WORK/mnt-$mode"
    unmount_backend "$WORK/mnt-$mode"
  done

  printf '\n%-8s %10s %10s %10s %12s %8s %8s\n' \
    backend clone stat read npm-install status files | tee -a "$RESULTS"
  while IFS=$'\t' read -r n c s r np st nf; do
    printf '%-8s %9sms %9sms %9sms %10sms %8s %8s\n' \
      "$n" "$c" "$s" "$r" "$np" "$st" "$nf" | tee -a "$RESULTS"
  done < "$WORK/raw.tsv"

  fork_report "$native_bytes"
}

# Fork cost, on the populated node_modules -- the state an agent sandbox would
# actually be forked from.
fork_report() {
  local native_bytes=$1
  log ""
  log "fork of the post-npm-install state:"

  local t0 t1
  t0=$(now); cp -a "$WORK/native" "$WORK/native-fork"; t1=$(now)
  log "$(printf '%-8s %8sms %12s' native "$(ms "$t0" "$t1")" "$(human "$(bytes_of "$WORK/native-fork")")")"

  # inline: whole-file copy, the branch demo's fork. O(size).
  t0=$(now); cp "$WORK/inline.db" "$WORK/inline-fork.db"; t1=$(now)
  log "$(printf '%-8s %8sms %12s' inline "$(ms "$t0" "$t1")" "$(human "$(bytes_of "$WORK/inline-fork.db")")")"

  # cas: copy metadata only, share the blob table.
  t0=$(now)
  sqlite3 "$WORK/cas.db" <<SQL
ATTACH DATABASE '$WORK/cas-fork.db' AS fork;
CREATE TABLE fork.inodes AS SELECT * FROM inodes;
CREATE TABLE fork.dirents AS SELECT * FROM dirents;
CREATE TABLE fork.ino_content AS SELECT * FROM ino_content;
DETACH DATABASE fork;
SQL
  t1=$(now)
  log "$(printf '%-8s %8sms %12s' cas "$(ms "$t0" "$t1")" "$(human "$(bytes_of "$WORK/cas-fork.db")")")"

  # cas trades a bigger parent for a cheap fork; this says how much of that is
  # blobs whose files were deleted, which a real implementation would collect.
  log ""
  log "what is in the cas parent:"
  sqlite3 "$WORK/cas.db" "
    SELECT '  live blobs   ' || count(*) || '  ' || COALESCE(sum(length(content))/1048576, 0) || ' MB'
      FROM blobs WHERE hash IN (SELECT hash FROM ino_content);
    SELECT '  orphan blobs ' || count(*) || '  ' || COALESCE(sum(length(content))/1048576, 0) || ' MB'
      FROM blobs WHERE hash NOT IN (SELECT hash FROM ino_content);
    SELECT '  dedup: ' || (SELECT count(*) FROM ino_content) || ' files -> '
      || (SELECT count(DISTINCT hash) FROM ino_content) || ' distinct blobs';
  " | tee -a "$RESULTS"

  log ""
  log "for reference, the parent databases:"
  log "$(printf '%-8s %12s' inline "$(human "$(bytes_of "$WORK/inline.db")")")"
  log "$(printf '%-8s %12s' cas "$(human "$(bytes_of "$WORK/cas.db")")")"
  log "$(printf '%-8s %12s' native "$(human "$native_bytes")")"
}

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"; }

main "$@"
