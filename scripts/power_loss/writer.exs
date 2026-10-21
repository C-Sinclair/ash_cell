# Writes acknowledged commits to one cell on a dm-log-writes device, for ADR-20.
#
# Each commit goes through a real AshCell cell (`AshCell.Test.BoundPatient` on
# `AshCell.TestRepo`), so it runs with the connection options every cell runs with.
# After each commit returns, and only then, this asks dm-log-writes to put a mark
# named `ack_<n>` in its log. Replaying the log up to that mark is the disk as a
# power cut at that moment would leave it, and row n must be on it.
#
# `run.sh` drives this; it is not meant to be run on its own.
#
#     MIX_ENV=test mix run scripts/power_loss/writer.exs <dir> <synchronous> <commits> <dm-name>

[dir, synchronous, commits, dm_name] = System.argv()
commits = String.to_integer(commits)

level =
  case synchronous do
    "default" -> nil
    level when level in ~w(off normal full extra) -> String.to_existing_atom(level)
  end

# `synchronous` reaches exqlite through the repo's otp_app config, which Ecto merges
# into every instance a cell starts.
if level do
  config = Application.get_env(:ash_cell, AshCell.TestRepo, [])
  Application.put_env(:ash_cell, AshCell.TestRepo, Keyword.put(config, :synchronous, level))
end

{:ok, _} =
  Supervisor.start_link(
    [
      {AshCell,
       repo: AshCell.TestRepo, dir: dir, migrations_path: AshCell.TestMigrations.path(:test)}
    ],
    strategy: :one_for_one
  )

cell = "power_loss"

for n <- 1..commits do
  AshCell.Test.BoundPatient.create!("row-#{n}", tenant: cell)
  {_, 0} = System.cmd("sudo", ["dmsetup", "message", dm_name, "0", "mark", "ack_#{n}"])
end

IO.puts("wrote #{commits} acknowledged commits at synchronous=#{synchronous}")
