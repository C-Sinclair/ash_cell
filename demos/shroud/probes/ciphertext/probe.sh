#!/usr/bin/env bash
# Probe: does a SQLCipher database leak plaintext into its main file or its WAL?
#
# Stands in for the Litestream probe. Litestream replicates WAL frames verbatim, so
# "are the S3 segments ciphertext?" reduces to "are the WAL frames ciphertext?", which
# is answerable without Litestream installed.
#
# The WAL half needs care: SQLite checkpoints and deletes the WAL on clean close, so a
# script that opens, writes and exits leaves nothing to inspect and a naive probe reports
# a pass it never earned. Here the writer is held open on a FIFO while the files are
# inspected, then killed uncleanly, which is also the realistic case -- a WAL only exists
# on disk for Litestream to ship when a connection is live or a node died.
set -euo pipefail
cd "$(dirname "$0")"
D=$(mktemp -d); trap 'rm -rf "$D"; kill %1 2>/dev/null || true' EXIT
MARK="PLAINTEXT_CANARY_8f3a91"
HEX=$(openssl rand -hex 32)
fail=0

check() { # file label required
  if [ ! -f "$1" ]; then
    if [ "${3:-}" = "required" ]; then echo "  $2: ABSENT -- claim untested  <-- FAIL"; fail=1
    else echo "  $2: absent"; fi
    return
  fi
  if LC_ALL=C grep -q "$MARK" "$1" 2>/dev/null; then
    echo "  $2: LEAKS the canary  <-- FAIL"; fail=1
  else
    echo "  $2: no plaintext ($(wc -c <"$1" | tr -d ' ') bytes)"
  fi
}

run_held() { # dbfile keypragma outvar_prefix -- writes, then holds the connection open
  local db="$1" keypragma="$2"
  local fifo="$D/fifo.$(basename "$db")"
  mkfifo "$fifo"
  sqlcipher "$db" < "$fifo" >/dev/null 2>&1 &
  exec 3>"$fifo"
  {
    [ -n "$keypragma" ] && echo "$keypragma"
    echo "PRAGMA journal_mode = WAL;"
    echo "PRAGMA wal_autocheckpoint = 0;"
    echo "CREATE TABLE profile_field (id TEXT, ciphertext TEXT);"
    echo "INSERT INTO profile_field VALUES ('1', '$MARK');"
    echo "SELECT count(*) FROM profile_field;"
  } >&3
  sleep 1                      # let the writer flush the WAL before we look
  # connection is still open on fd 3, so the WAL is still on disk
}

release_held() { exec 3>&-; sleep 0.3; kill %1 2>/dev/null || true; wait 2>/dev/null || true; }

echo "== encrypted, WAL mode, connection held open =="
run_held "$D/enc.db" "PRAGMA key = \"x'$HEX'\";"
check "$D/enc.db"     "main file" required
check "$D/enc.db-wal" "WAL"       required
release_held

echo "== control: unencrypted, same procedure (must leak, or the probe proves nothing) =="
run_held "$D/plain.db" ""
leaked=0
for f in "$D/plain.db" "$D/plain.db-wal"; do
  [ -f "$f" ] && LC_ALL=C grep -q "$MARK" "$f" 2>/dev/null && { echo "  $(basename "$f"): leaks as expected"; leaked=1; }
done
[ -f "$D/plain.db-wal" ] || { echo "  control WAL absent -- procedure does not retain a WAL  <-- FAIL"; fail=1; }
[ $leaked -eq 1 ] || { echo "  control did NOT leak -- probe is not measuring what it claims  <-- FAIL"; fail=1; }
release_held

echo "== header check: encrypted file must not start with 'SQLite format 3' =="
hdr=$(head -c 15 "$D/enc.db" | LC_ALL=C tr -d '\0')
if [ "$hdr" = "SQLite format 3" ]; then echo "  header is plaintext  <-- FAIL"; fail=1
else echo "  header is opaque: $(head -c 8 "$D/enc.db" | xxd -p)"; fi

echo
if [ $fail -eq 0 ]; then
  echo "VERDICT: main file AND WAL frames are ciphertext, with an unencrypted control that"
  echo "         leaks under the same procedure. Shred lever 2 covers replicated WAL segments."
  echo "         Still unverified: that Litestream itself adds no plaintext framing. Install"
  echo "         litestream and re-check before claiming the S3 objects are wholly opaque."
else
  echo "VERDICT: FAILED -- do not claim lever 2 covers S3 history."
fi
exit $fail
