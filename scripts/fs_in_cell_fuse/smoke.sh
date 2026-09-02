#!/usr/bin/env bash
# Correctness smoke test for fs_in_cell_fuse. Runs INSIDE a Linux container with /dev/fuse.
# See run_smoke.sh for the docker wrapper that gets it there from macOS.
set -euo pipefail

DAEMON=${DAEMON:-/src/target/release/fs_in_cell_fuse}
WORK=${WORK:-/work}
MODE=${MODE:-cas}
DB="$WORK/test.db"
MNT="$WORK/mnt"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

mount_fs() {
  mkdir -p "$MNT"
  "$DAEMON" --db "$DB" --mode "$MODE" --mount "$MNT" &
  DAEMON_PID=$!
  for _ in $(seq 1 100); do
    mountpoint -q "$MNT" && return 0
    sleep 0.1
  done
  fail "daemon did not mount within 10s"
}

unmount_fs() {
  fusermount3 -u "$MNT" 2>/dev/null || fusermount -u "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
}

rm -rf "$WORK"
mkdir -p "$WORK"

mount_fs

# 1. nested mkdir, write, read
mkdir -p "$MNT/a/b/c"
echo hello > "$MNT/a/b/c/f"
[ "$(cat "$MNT/a/b/c/f")" = "hello" ] || fail "1: nested write/read"
pass "1: mkdir -p, write, cat"

# 2. 5MB file round trip
dd if=/dev/urandom of="$WORK/src5m" bs=1M count=5 status=none
cp "$WORK/src5m" "$MNT/a/b/c/big"
sync
sum_src=$(sha256sum "$WORK/src5m" | cut -d' ' -f1)
sum_mnt=$(sha256sum "$MNT/a/b/c/big" | cut -d' ' -f1)
[ "$sum_src" = "$sum_mnt" ] || fail "2: 5MB sha256 mismatch ($sum_src != $sum_mnt)"
pass "2: 5MB write/read sha256 match"

# 3. symlink
ln -s f "$MNT/a/b/c/link"
[ "$(readlink "$MNT/a/b/c/link")" = "f" ] || fail "3: readlink"
[ "$(cat "$MNT/a/b/c/link")" = "hello" ] || fail "3: cat through symlink"
pass "3: symlink create, readlink, cat-through"

# 4. rename, then overwrite-rename
mv "$MNT/a/b/c/f" "$MNT/a/b/c/g"
[ -f "$MNT/a/b/c/g" ] || fail "4: rename target missing"
[ ! -e "$MNT/a/b/c/f" ] || fail "4: rename source still present"
echo other > "$MNT/a/b/c/h"
mv "$MNT/a/b/c/g" "$MNT/a/b/c/h"
[ "$(cat "$MNT/a/b/c/h")" = "hello" ] || fail "4: overwrite-rename content wrong"
[ ! -e "$MNT/a/b/c/g" ] || fail "4: overwrite-rename source still present"
pass "4: rename and overwrite-rename"

# 5. rm, rmdir, ls -la
rm "$MNT/a/b/c/h" "$MNT/a/b/c/big" "$MNT/a/b/c/link"
rmdir "$MNT/a/b/c"
rmdir "$MNT/a/b"
ls -la "$MNT/a" >/dev/null
[ -d "$MNT/a" ] || fail "5: dir a missing"
[ ! -e "$MNT/a/b" ] || fail "5: b should be gone"
rmdir "$MNT/a"
[ ! -e "$MNT/a" ] || fail "5: a should be gone"
pass "5: rm, rmdir, ls -la"

# 6. tar extraction, diff -r against source tree
mkdir -p "$WORK/tarsrc/nested/dir"
echo "one" > "$WORK/tarsrc/file1.txt"
echo "two" > "$WORK/tarsrc/nested/file2.txt"
dd if=/dev/urandom of="$WORK/tarsrc/nested/dir/bin.dat" bs=1k count=37 status=none
tar cf "$WORK/tarsrc.tar" -C "$WORK/tarsrc" .
mkdir -p "$MNT/extracted"
tar xf "$WORK/tarsrc.tar" -C "$MNT/extracted"
diff -r "$WORK/tarsrc" "$MNT/extracted" || fail "6: diff -r found differences"
pass "6: tar extraction matches source tree"

# 7. npm install acceptance test
mkdir -p "$MNT/pkg"
cat > "$MNT/pkg/package.json" <<'JSON'
{
  "name": "fs-in-cell-smoke",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "lodash": "4.17.21",
    "chalk": "5.3.0"
  }
}
JSON
(cd "$MNT/pkg" && npm install --no-audit --no-fund --loglevel=error)
node -e "const l = require('$MNT/pkg/node_modules/lodash'); if (l.chunk([1,2,3],2).length !== 2) throw new Error('lodash broken');"
pass "7: npm install + require() inside the mount"

unmount_fs

# 8. remount from the same db file, verify content survived
mount_fs
[ "$(cat "$MNT/extracted/file1.txt")" = "one" ] || fail "8: file1.txt missing after remount"
[ "$(cat "$MNT/extracted/nested/file2.txt")" = "two" ] || fail "8: file2.txt missing after remount"
sum_after=$(sha256sum "$MNT/extracted/nested/dir/bin.dat" | cut -d' ' -f1)
sum_before=$(sha256sum "$WORK/tarsrc/nested/dir/bin.dat" | cut -d' ' -f1)
[ "$sum_after" = "$sum_before" ] || fail "8: bin.dat mismatch after remount"
[ -d "$MNT/pkg/node_modules/lodash" ] || fail "8: node_modules/lodash missing after remount"
unmount_fs
pass "8: unmount/remount preserves content"

echo "ALL CHECKS PASSED (mode=$MODE)"
