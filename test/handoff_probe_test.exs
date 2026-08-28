defmodule AshCell.HandoffProbeTest do
  @moduledoc """
  A probe, not a feature: the narrowest questions that decide whether AshCell should
  own a record handoff between cells, and what such a handoff may key itself by.
  See [ADR-25](../docs/decisions/ADR-25-no-record-handoff-in-the-library.md).

  Nothing here exercises library code that does not already exist. The handoff is
  driven by hand, in raw SQL, against two real cells and a real bucket — which is
  the point: if the sequence can be written correctly out of the pieces that are
  already here, the library does not need a module for it, and if it cannot, the
  probe is where that shows up.

  The load-bearing test is `a repeat under a new attempt id`. Everything else could
  pass and that one fail, and the failure would be a note that exists twice in the
  cell that is supposed to be the record of it.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  @moduletag :object_store
  @moduletag :capture_log

  alias AshCell.{Lease, Replicator}

  setup :require_object_store

  setup %{store: store} do
    dir = Path.join(System.tmp_dir!(), "ash_cell_handoff_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrator: AshCell.HandoffProbeMigrations,
       store: store,
       owner: "node-a",
       snapshot: false}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp adopt(store, cell) do
    {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
    :ok = AshCell.Manager.put_lease(cell, lease)
    cell
  end

  # Raw SQL against the cell's own repo pid, as `test/branch_test.exs` does. A
  # handoff is a question about ordering across two databases; driving it through
  # the resource path would couple the probe to the tenancy runtime without
  # answering anything more about the ordering.
  defp repo_pid(cell) do
    {:ok, pid} = AshCell.Manager.ensure_started(cell)
    AshCell.Cell.repo_pid(pid)
  end

  defp sql!(cell, query, params),
    do: Ecto.Adapters.SQL.query!(repo_pid(cell), query, params)

  defp rows(cell, query, params), do: sql!(cell, query, params).rows

  defp note(cell, id) do
    case rows(cell, "SELECT body, handoff_state, promoted_to FROM vault_notes WHERE id = ?1", [id]) do
      [[body, state, promoted_to]] -> %{body: body, state: state, promoted_to: promoted_to}
      [] -> nil
    end
  end

  defp source_with_note(store, prefix) do
    cell = adopt(store, unique_cell(prefix))
    id = Ecto.UUID.generate()
    sql!(cell, "INSERT INTO vault_notes (id, body) VALUES (?1, ?2)", [id, "the note"])
    {cell, id}
  end

  # Phase 1. One transaction in the source, which is single-writer, so the state
  # transition and the check that it is legal are decided together. This is the
  # fence: after it commits the source still *owns* the record and still serves
  # reads of it, and no longer accepts writes to it.
  defp reserve(cell, id) do
    attempt = Ecto.UUID.generate()

    %{num_rows: 1} =
      sql!(
        cell,
        "UPDATE vault_notes SET handoff_state = 'reserved', handoff_id = ?2 WHERE id = ?1 AND handoff_state = 'owned'",
        [id, attempt]
      )

    attempt
  end

  # Phase 2. Idempotent on the *record's* identity. `attempt` is carried for
  # correlation only and is deliberately not part of the key -- which is the whole
  # question this probe exists to settle.
  defp import_record(target, source_cell, id, body, attempt) do
    sql!(
      target,
      "INSERT INTO imports (source_cell, record_id, attempt_id) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING",
      [source_cell, id, attempt]
    )

    sql!(target, "INSERT INTO imported_notes (id, body) VALUES (?1, ?2) ON CONFLICT DO NOTHING", [
      id,
      body
    ])
  end

  # The same import keyed by the attempt instead, kept so the difference can be
  # shown rather than asserted.
  defp import_by_attempt(target, source_cell, id, attempt) do
    sql!(
      target,
      "INSERT INTO imports_by_attempt (source_cell, record_id, attempt_id) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING",
      [source_cell, id, attempt]
    )
  end

  # Phase 3. Only after the target holds the record. Idempotent by being a
  # state transition that is already satisfied on a repeat.
  defp release(cell, id, target) do
    sql!(
      cell,
      "UPDATE vault_notes SET handoff_state = 'promoted', promoted_to = ?2 WHERE id = ?1 AND handoff_state IN ('reserved', 'promoted')",
      [id, target]
    )
  end

  describe "what a txid identifies" do
    test "the source's txid advances without the record changing", %{store: store} do
      {cell, id} = source_with_note(store, "handoff_txid")

      {:ok, %{txid: first}} = Replicator.ship(store, cell)
      {:ok, %{txid: second}} = Replicator.ship(store, cell)

      assert second == first + 1
      assert note(cell, id).body == "the note"
    end
  end

  describe "the target's import" do
    test "absorbs a repeat under the same attempt id", %{store: store} do
      {source, id} = source_with_note(store, "handoff_same")
      target = adopt(store, unique_cell("handoff_same_target"))

      attempt = reserve(source, id)
      import_record(target, source, id, "the note", attempt)
      import_record(target, source, id, "the note", attempt)

      assert rows(target, "SELECT count(*) FROM imported_notes", []) == [[1]]
    end

    test "absorbs a repeat under a new attempt id, where an attempt-keyed one duplicates",
         %{store: store} do
      {source, id} = source_with_note(store, "handoff_new_attempt")
      target = adopt(store, unique_cell("handoff_new_attempt_target"))

      first = reserve(source, id)
      import_record(target, source, id, "the note", first)
      import_by_attempt(target, source, id, first)

      # The source forgot the reservation and a second promotion was started. See
      # the restore test below for why that is a real state and not a hypothetical.
      sql!(
        source,
        "UPDATE vault_notes SET handoff_state = 'owned', handoff_id = NULL WHERE id = ?1",
        [id]
      )

      second = reserve(source, id)
      refute second == first

      import_record(target, source, id, "the note", second)
      import_by_attempt(target, source, id, second)

      assert rows(target, "SELECT count(*) FROM imports", []) == [[1]]
      assert rows(target, "SELECT count(*) FROM imported_notes", []) == [[1]]

      # The proposed key, which includes the attempt, admits the record twice.
      assert rows(target, "SELECT count(*) FROM imports_by_attempt", []) == [[2]]
    end
  end

  describe "an interrupted handoff" do
    test "leaves the source authoritative, readable and retryable", %{store: store} do
      {source, id} = source_with_note(store, "handoff_interrupted")
      target = adopt(store, unique_cell("handoff_interrupted_target"))

      attempt = reserve(source, id)
      import_record(target, source, id, "the note", attempt)

      # Interrupted here: the target holds the record and the source has not been
      # released. The source is still the record -- readable, and refusing writes.
      assert note(source, id).state == "reserved"
      assert note(source, id).body == "the note"
      assert note(source, id).promoted_to == nil

      assert %{num_rows: 0} =
               sql!(
                 source,
                 "UPDATE vault_notes SET body = ?2 WHERE id = ?1 AND handoff_state = 'owned'",
                 [id, "an edit that must not land"]
               )

      release(source, id, target)
      release(source, id, target)

      assert note(source, id).state == "promoted"
      assert note(source, id).promoted_to == target
      assert rows(target, "SELECT count(*) FROM imported_notes", []) == [[1]]
    end

    test "a source restored from a snapshot older than the reservation forgets it",
         %{store: store} do
      {source, id} = source_with_note(store, "handoff_amnesia")

      {:ok, %{txid: txid}} = Replicator.ship(store, source)
      assert reserve(source, id)
      assert note(source, id).state == "reserved"

      {:ok, _} = Replicator.restore(store, source, txid)

      assert note(source, id).state == "owned"
    end
  end
end
