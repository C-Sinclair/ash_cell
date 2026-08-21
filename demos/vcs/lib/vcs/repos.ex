defmodule Vcs.Repos do
  @moduledoc """
  Whether a repository exists at all.

  Worth its own module because of a subtlety: `AshCell.Manager.ensure_started/1` *creates* a
  cell for any name it is handed. That is right for a push — the first push is what brings a
  repository into being — and wrong for a read, where it means any `GET` on a typo'd name
  silently materialises an empty repository and a file on disk.

  So reads check here first, and the answer is a file-existence check rather than a query,
  because a query is exactly the thing that would create it.
  """

  def exists?(repo_name) do
    path = AshCell.path_for(repo_name)

    File.exists?(path)
  end
end
