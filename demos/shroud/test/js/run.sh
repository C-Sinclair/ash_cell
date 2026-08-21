#!/usr/bin/env bash
# Drives the JS <-> Elixir crypto interop check. Not part of `mix test`: it needs node
# and compiles the app twice, and a green mix suite should not depend on either.
#
# The scratch directory is passed through an *exported* variable. It has to be exported
# rather than merely assigned: the Elixir halves run in child processes, and a plain
# shell variable is invisible to them -- `System.get_env("T")` comes back nil and the
# script dies mid-run with the failure attributed to whatever ran next.
set -euo pipefail
cd "$(dirname "$0")/../.."
export T
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

run_elixir() { MIX_ENV=test mix run -e "$1" >/dev/null; }

echo "== JS-only key hierarchy =="
node test/js/interop.mjs selftest || fail=1

echo
echo "== Elixir seals -> JS opens =="
node test/js/interop.mjs keygen "$T/id.json"
run_elixir '
  path = System.fetch_env!("T") <> "/id.json"
  %{"public_key" => pk, "private_key" => sk} = path |> File.read!() |> Jason.decode!()
  {:ok, sealed} = Shroud.Sealing.seal_to(pk, "sealed by the server for an offline user")

  File.write!(
    path,
    Jason.encode!(%{
      private_key: sk,
      sealed: sealed,
      expected: "sealed by the server for an offline user"
    })
  )
'
node test/js/interop.mjs open "$T/id.json" || fail=1

echo
echo "== JS seals -> Elixir opens =="
run_elixir '
  path = System.fetch_env!("T") <> "/rev.json"
  {public_key, private_key} = Shroud.Sealing.generate_keypair()

  File.write!(
    path,
    Jason.encode!(%{
      public_key: public_key,
      private_key: Base.encode64(private_key),
      plaintext: "sealed in the browser for the server to store"
    })
  )
'
cp "$T/rev.json" "$T/rev.in.json"
node test/js/interop.mjs seal "$T/rev.json"
MIX_ENV=test mix run -e '
  t = System.fetch_env!("T")

  %{"private_key" => sk, "plaintext" => expected} =
    (t <> "/rev.in.json") |> File.read!() |> Jason.decode!()

  %{"sealed" => sealed} = (t <> "/rev.json") |> File.read!() |> Jason.decode!()

  case Shroud.Sealing.open(Base.decode64!(sk), sealed) do
    {:ok, ^expected} ->
      IO.puts("  ok    JS -> Elixir: #{expected}")

    other ->
      IO.puts("  FAIL  JS -> Elixir: #{inspect(other)}")
      System.halt(1)
  end
' 2>/dev/null || fail=1

echo
if [ $fail -eq 0 ]; then
  echo "VERDICT: the browser and server implementations agree."
else
  echo "VERDICT: FAILED -- the two implementations disagree."
fi
exit $fail
