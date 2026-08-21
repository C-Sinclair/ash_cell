# Probe: what does a pull-model feed cost?
#
# The feed reads one row from each of N different users' cells. Every other design
# question in docs/prd.md is downstream of this number, so it is measured before
# any UI exists to hide it.
#
#   mix run probes/checkout/run.exs [n_owners]
#
# Measures three things separately, because "the feed is slow" is not actionable
# but "the lease is slow" is:
#   cold  -- cells not resident; includes open + SQLCipher key derivation + migrate
#   warm  -- cells resident; the steady-state cost of binding and querying
#   bound -- one cell, N queries; the floor, isolating query cost from checkout cost

Logger.configure(level: :warning)
require Ash.Query
alias Shroud.Profile

n = case System.argv() do
  [arg | _] -> String.to_integer(arg)
  [] -> 50
end

owners = for i <- 1..n, do: "probe-owner-#{i}"

blob = Base.encode64(:crypto.strong_rand_bytes(96))
iv = Base.encode64(:crypto.strong_rand_bytes(12))

IO.puts("seeding #{n} cells…")

for owner <- owners do
  Profile.Field.put!(
    %{key: "display_name", ciphertext: blob, iv: iv, content_key_id: "ck-1"},
    tenant: owner
  )
end

pct = fn sorted, p ->
  idx = max(0, min(length(sorted) - 1, round(p / 100 * length(sorted)) - 1))
  Enum.at(sorted, idx)
end

report = fn label, samples ->
  s = Enum.sort(samples)
  total = Enum.sum(samples)
  IO.puts([
    String.pad_trailing(label, 34),
    "p50 ", String.pad_leading("#{div(pct.(s, 50), 1000)}", 5), "µs  ",
    "p95 ", String.pad_leading("#{div(pct.(s, 95), 1000)}", 6), "µs  ",
    "p99 ", String.pad_leading("#{div(pct.(s, 99), 1000)}", 6), "µs  ",
    "total ", String.pad_leading("#{Float.round(total / 1_000_000, 1)}", 6), "ms"
  ])
end

read_one = fn owner ->
  {us, _} = :timer.tc(fn -> Profile.Field.by_key!("display_name", tenant: owner) end)
  us * 1000
end

# Cold: evict everything first so each read pays for an open.
IO.puts("\n== cold (cells closed before each pass) ==")
for owner <- owners, do: AshCell.close(owner)
cold = Enum.map(owners, read_one)
report.("feed of #{n}, cold", cold)

IO.puts("\n== warm (cells resident) ==")
warm1 = Enum.map(owners, read_one)
report.("feed of #{n}, warm pass 1", warm1)
warm2 = Enum.map(owners, read_one)
report.("feed of #{n}, warm pass 2", warm2)

IO.puts("\n== floor: one cell, #{n} queries ==")
one = hd(owners)
bound = Enum.map(1..n, fn _ -> read_one.(one) end)
report.("same cell, #{n} reads", bound)

checkout_overhead = Enum.sum(warm2) - Enum.sum(bound)

IO.puts("""

== what this says ==
Warm feed of #{n}:        #{Float.round(Enum.sum(warm2) / 1_000_000, 1)}ms
Same work, one cell:      #{Float.round(Enum.sum(bound) / 1_000_000, 1)}ms
Attributable to checkout: #{Float.round(checkout_overhead / 1_000_000, 1)}ms \
(#{round(checkout_overhead / max(Enum.sum(warm2), 1) * 100)}% of the warm feed)
Cold penalty:             #{Float.round((Enum.sum(cold) - Enum.sum(warm2)) / 1_000_000, 1)}ms

Caveats, so these numbers are not over-read: single node, loopback, no lease
contention, no other tenants resident, max_resident=#{Application.get_env(:shroud, :max_resident, 64)}. \
Cross-node routing and eviction churn are not measured here and both make it worse.
""")
