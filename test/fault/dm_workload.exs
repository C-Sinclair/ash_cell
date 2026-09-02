# The workload half of ADR-20 tier 3, driven by scripts/dm_log_writes_test.sh.
#
# Deliberately smaller than the tier 1 and 2 probes: it writes a cell onto a
# device that is being recorded at the block layer, and records which commits it
# received an acknowledgement for. It makes no assertions itself. The verdict is
# reached after the device is replayed, by test/fault/dm_verify.exs, against a
# filesystem this process never sees.
#
# The acknowledged set is written outside the logged device on purpose. Anything
# written to the cell's own filesystem would be replayed along with it and could
# vanish at exactly the cut being checked, leaving the verifier with no record of
# what it was supposed to find.

dir = System.fetch_env!("PROBE_CELL_DIR")
level = System.get_env("PROBE_SYNC", "full") |> String.to_atom()
rows = 20

Application.put_env(:ash_cell, AshCell.TestRepo, synchronous: level)

{:ok, _} =
  Supervisor.start_link(
    [{AshCell, repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations}],
    strategy: :one_for_one
  )

acknowledged =
  for i <- 1..rows do
    AshCell.Test.TenantPatient.create!("Patient #{i}", tenant: "dm")
    "Patient #{i}"
  end

AshCell.close("dm")

File.write!(
  System.get_env("PROBE_ACK_FILE", "/tmp/ash_cell_dm/acknowledged.txt"),
  Enum.join(acknowledged, "\n")
)

IO.puts("wrote #{length(acknowledged)} acknowledged commits under synchronous: #{level}")
