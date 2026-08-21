defmodule Shroud.Cells.Schema do
  @moduledoc """
  Versioned schema for one user's cell, applied on activation before the cell
  serves traffic.

  Migration here is a fleet operation, and there is no moment at which every user
  is on the same schema. The mitigation is blast radius: a failure takes out one
  user rather than all of them, and `AshCell.Manager.quarantined/0` records it
  rather than logging it into the night.

  Run `mix ash_cell.migrate` at deploy time so failures surface while somebody is
  watching. Lazy activation is the fallback, not the plan.

  Note that the ciphertext columns are `TEXT`. The payloads are base64 rather than
  raw `BLOB`, because they cross into JavaScript on every read and back on every
  write, and base64 is what `JSON.stringify` can carry without a second encoding
  step. The cost is ~33% on the ciphertext columns, paid to keep exactly one
  encoding boundary in the system instead of two.
  """
  use AshCell.Migrator

  migration(1, """
  CREATE TABLE profile_fields (
    id TEXT PRIMARY KEY,
    key TEXT NOT NULL,
    ciphertext TEXT NOT NULL,
    iv TEXT NOT NULL,
    content_key_id TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  """)

  migration(2, "CREATE UNIQUE INDEX profile_fields_key ON profile_fields(key)")

  migration(3, """
  CREATE TABLE audiences (
    id TEXT PRIMARY KEY,
    slug TEXT NOT NULL,
    name TEXT NOT NULL,
    wrapped_group_key TEXT NOT NULL,
    iv TEXT NOT NULL,
    generation INTEGER NOT NULL DEFAULT 1,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  """)

  migration(4, "CREATE UNIQUE INDEX audiences_slug ON audiences(slug)")

  migration(5, """
  CREATE TABLE grants (
    id TEXT PRIMARY KEY,
    field_key TEXT NOT NULL,
    audience_slug TEXT NOT NULL,
    wrapped_content_key TEXT NOT NULL,
    iv TEXT NOT NULL,
    generation INTEGER NOT NULL DEFAULT 1,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  """)

  migration(6, "CREATE UNIQUE INDEX grants_field_audience ON grants(field_key, audience_slug)")

  migration(7, """
  CREATE TABLE inbox_items (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    ciphertext TEXT NOT NULL,
    iv TEXT NOT NULL,
    ephemeral_public_key TEXT NOT NULL,
    sender_handle TEXT,
    read_at TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  """)

  # The feed reads grants by audience, so that lookup is the one worth an index.
  migration(8, "CREATE INDEX grants_audience ON grants(audience_slug)")

  # Posts. `body` holds plaintext for public posts and stays NULL for audience posts,
  # which store `ciphertext` instead -- see Shroud.Profile.Post for why a public post
  # is deliberately not encrypted.
  migration(9, """
  CREATE TABLE posts (
    id TEXT PRIMARY KEY,
    visibility TEXT NOT NULL,
    body TEXT,
    ciphertext TEXT,
    iv TEXT,
    content_key_id TEXT,
    wrapped_content_key TEXT,
    wrap_iv TEXT,
    own_wrapped_content_key TEXT,
    own_wrap_iv TEXT,
    posted_at TEXT NOT NULL
  )
  """)

  # A timeline reads a page of ids and sorts by time, so both get an index.
  migration(10, "CREATE INDEX posts_posted_at ON posts(posted_at DESC)")
end
