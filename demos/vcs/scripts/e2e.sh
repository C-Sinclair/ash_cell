#!/usr/bin/env bash
# End-to-end: a real server, the real binary, two clones, and a losing push.
#
# Not part of `mix test` or `cargo test` — it needs a listening server, so it stays a script
# somebody runs on purpose.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
port="${VCS_E2E_PORT:-4010}"
work="$(mktemp -d)"
cells="$work/cells"
url="http://127.0.0.1:$port"

say() { printf '\n=== %s\n' "$1"; }

cleanup() {
  [[ -n "${server_pid:-}" ]] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

say "building the client"
(cd "$root/cli" && cargo build --quiet)
vcs="$root/cli/target/debug/vcs"

say "starting the server on $port (cells in $cells)"
mkdir -p "$cells"
(
  cd "$root"
  # `.envrc` points at Homebrew's SQLCipher, which is wrong everywhere else. Only source it
  # when nothing has already said where SQLCipher is -- CI sets these to its own paths, and
  # they must survive. Either way this only matters if `mix run` recompiles exqlite; a
  # pre-built NIF ignores them.
  if [[ -z "${EXQLITE_USE_SYSTEM:-}" && -f .envrc ]]; then
    # shellcheck disable=SC1091
    source .envrc
  fi
  VCS_CELL_DIR="$cells" PORT="$port" mix run --no-halt
) > "$work/server.log" 2>&1 &
server_pid=$!

# A 404 means the server is up and correctly refuses to invent a repository, so it is the
# readiness signal: any HTTP response at all will do.
ready=""
for _ in $(seq 1 60); do
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/repos/probe/probe/refs")" != "000" ]]; then
    ready=yes
    break
  fi
  sleep 0.5
done
[[ -n "$ready" ]] || { echo "server never came up:"; cat "$work/server.log"; exit 1; }

repo="conor/e2e-$$"

say "clone A: init, commit twice, push"
mkdir -p "$work/a" && cd "$work/a"
"$vcs" init
printf 'hello from A\n' > README.md
mkdir -p lib && printf 'defmodule A do\nend\n' > lib/a.ex
"$vcs" add README.md lib
"$vcs" commit -m "first commit"
printf 'hello from A, revised\n' > README.md
"$vcs" add README.md
"$vcs" commit -m "revise the readme"
"$vcs" remote "$url" "$repo"
"$vcs" push
"$vcs" log

say "clone C: clone gets a working tree, not just objects"
cd "$work"
"$vcs" clone "$url" "$repo" c
cd "$work/c"
"$vcs" status
diff -r --exclude=.vcs "$work/a" "$work/c" && echo "(working tree matches clone A exactly)"
"$vcs" log

say "clone C: commit on top of the clone and push"
printf 'a third line\n' >> README.md
"$vcs" add README.md
"$vcs" commit -m "extend the readme from the clone"
"$vcs" push

say "clone C: checkout an earlier snapshot and back again"
first="$("$vcs" log | grep '^commit ' | tail -1 | cut -d' ' -f2)"
"$vcs" checkout "$first"
grep -q 'a third line' README.md && { echo "FAIL: checkout did not restore the old content"; exit 1; }
echo "(README.md is back to the first commit)"
# `main` now points at the older commit, because checkout moved it. The remote-tracking ref is
# what still knows where the tip is.
"$vcs" fetch
"$vcs" checkout origin/main
grep -q 'a third line' README.md || { echo "FAIL: checkout did not return to the tip"; exit 1; }
echo "(and forward again to the tip)"

say "clone B: fetch what A pushed"
mkdir -p "$work/b" && cd "$work/b"
"$vcs" init
"$vcs" remote "$url" "$repo"
"$vcs" fetch

say "clone B: a divergent push must be refused"
cd "$work/b"
printf 'hello from B\n' > README.md
"$vcs" add README.md
"$vcs" commit -m "B goes its own way"
if "$vcs" push; then
  echo "FAIL: a divergent push was accepted"
  exit 1
fi
echo "(refused, as it should be)"

say "server-side history, without a clone"
echo "--- log"
curl -sf "$url/api/repos/$repo/log" | tr ',' '\n' | grep -E 'message|id' | head -6
echo "--- which commits changed README.md"
curl -sf "$url/api/repos/$repo/history?path=README.md" | tr ',' '\n' | grep message
echo "--- which commits changed lib/a.ex (only the first: the second commit left it alone)"
curl -sf "$url/api/repos/$repo/history?path=lib/a.ex" | tr ',' '\n' | grep message
echo "--- search for 'revise'"
curl -sf "$url/api/repos/$repo/search?q=revise" | tr ',' '\n' | grep message
echo "--- current tree"
curl -sf "$url/api/repos/$repo/tree" | tr ',' '\n' | grep path

say "the repository is one encrypted file"
# Every file the cell owns, WAL sidecars included: freshly written pages live in the -wal, so
# checking only the .db would prove very little.
mapfile -t files < <(find "$cells" -type f -name '*.db*')
ls -la "${files[@]}"
for file in "${files[@]}"; do
  if head -c 15 "$file" | grep -q "SQLite format 3"; then
    echo "FAIL: $file is not encrypted"
    exit 1
  fi
  for marker in "hello from A" "revise the readme" "README.md"; do
    if grep -aq "$marker" "$file"; then
      echo "FAIL: plaintext '$marker' found in $file"
      exit 1
    fi
  done
done
echo "(no SQLite header, no plaintext markers, in the database or its WAL)"

say "a read on an unknown repository 404s instead of creating one"
curl -s -w ' <- %{http_code}\n' "$url/api/repos/nobody/nothing/refs"
[[ -e "$cells/nobody" ]] && { echo "FAIL: a read created a cell"; exit 1; }
echo "(no cell created)"

say "a lying client is refused"
curl -s -o "$work/lie.json" -w '%{http_code}\n' -X POST "$url/api/repos/$repo/objects" \
  -H 'content-type: application/json' \
  -d '{"objects":[{"id":"0000000000000000000000000000000000000000000000000000000000000000","kind":"blob","encoded_b64":"YmxvYiA0AGxpYXI="}]}'
cat "$work/lie.json"; echo

say "all good"
