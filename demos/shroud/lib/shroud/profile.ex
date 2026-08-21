defmodule Shroud.Profile do
  @moduledoc """
  One user's profile, living in that user's own cell.

  Note what is absent from every resource here: a `user_id` column, and any filter
  on one. The user *is* the database. There is no shared table for a missing
  `WHERE` clause to leak across, which is the whole reason this sits on AshCell.

  Every resource here carries `AshCell.Resource`, so each action binds its own cell
  for the statement it is about to issue and releases it afterwards. Nothing here
  relies on an inherited binding — the binding is ambient and does not survive a
  `Task`, an `Ash.load` fan-out, or a job boundary.
  """
  use Ash.Domain

  resources do
    resource(Shroud.Profile.Field)
    resource(Shroud.Profile.Audience)
    resource(Shroud.Profile.Grant)
    resource(Shroud.Profile.InboxItem)
    resource(Shroud.Profile.Post)
  end
end
