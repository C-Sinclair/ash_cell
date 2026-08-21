defmodule Shroud.Global do
  @moduledoc """
  The global Postgres database: everything that is not owned by one user.

  Two kinds of thing live here, and the distinction matters.

  **Key material wrappers.** Every wrap of a user's master key is a row in
  `KeyWrap`. The plaintext master key never reaches this database, or any other —
  it is generated in the browser and stays there. Deleting a user's `KeyWrap` rows
  is the cryptoshred: the master key becomes unrecoverable and every Tier 1
  ciphertext in that user's cell turns to noise, while the cell file itself stays
  intact so other users' share edges still resolve.

  **Tier 0 index data.** Handles, audience membership, feed edges. Server-visible
  by construction, because the feed has to sort and page somewhere, and it cannot
  sort ciphertext.

  This is a different repo *module* from `Shroud.CellRepo`, which is not
  cosmetic. Ecto's dynamic binding is per repo module, so a resource sharing the
  cells' module would inherit whatever tenant binding happened to be ambient and
  write its rows into an arbitrary user's database.
  """
  use Ash.Domain

  resources do
    resource(Shroud.Global.User)
    resource(Shroud.Global.Credential)
    resource(Shroud.Global.KeyWrap)
    resource(Shroud.Global.AudienceMember)
    resource(Shroud.Global.FeedEdge)
    resource(Shroud.Global.PostRef)
  end
end
