defmodule Shroud do
  @moduledoc """
  A zero-knowledge profile app on AshCell.

  One encrypted SQLite cell per user, keys derived in the browser from a passkey
  and never sent to the server, per-audience sharing, and account deletion that
  destroys key material rather than data.

  See `docs/prd.md` for the design, the threat model, and what this deliberately
  does not claim.
  """
end
