defmodule Vcs.Vault do
  @moduledoc """
  Per-repository encryption keys, derived rather than minted.

  A random key held in memory would be lost on restart, leaving every existing cell encrypted
  under a key nobody has. So the key is HKDF-shaped: derivable from a root secret and the
  repository name, forever. In a real deployment the root is a KMS key and this function
  unwraps on demand — same property.

  Revoking a repository's key crypto-shreds exactly one repository. Nobody else's bytes move.

  This is encryption at rest, not confidential computing: the node holds the plaintext key in
  order to serve.
  """

  @doc "The key for `repo_name`, or `nil` once revoked."
  def key_for(repo_name) do
    if revoked?(repo_name), do: nil, else: derive(repo_name)
  end

  @doc "Short stable fingerprint for display. Never reveals the key."
  def fingerprint(repo_name) do
    if revoked?(repo_name) do
      nil
    else
      :crypto.hash(:sha256, derive(repo_name))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)
    end
  end

  @doc "Destroys a repository's key. The bytes survive and are permanently meaningless."
  def revoke(repo_name) do
    AshCell.close(repo_name)
    File.mkdir_p!(Path.dirname(revocation_path()))
    File.write!(revocation_path(), Enum.join(Enum.uniq([repo_name | revoked()]), "\n"))
    :ok
  end

  @doc """
  Restores a revoked key. A demo affordance; a real vault cannot do this.

  Clearing the quarantine is the part that is easy to forget. A cell that failed to open for
  want of a key is quarantined, and a quarantine is sticky on purpose — otherwise every request
  would retry a broken activation. Handing the key back does not by itself make the repository
  serve again.
  """
  def unrevoke(repo_name) do
    AshCell.close(repo_name)
    File.write!(revocation_path(), Enum.join(revoked() -- [repo_name], "\n"))
    AshCell.Manager.release(repo_name)
    :ok
  end

  def revoked?(repo_name), do: repo_name in revoked()

  defp revoked do
    case File.read(revocation_path()) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      _ -> []
    end
  end

  defp revocation_path, do: Path.join(cell_dir(), ".revoked")

  defp cell_dir, do: Application.get_env(:vcs, :cell_dir, "priv/cells")

  # exqlite interpolates the value straight into `PRAGMA key = <value>`, so it must arrive as
  # a valid SQL literal. `"x'<hex>'"` is SQLCipher's raw-key form: the 256 bits verbatim, with
  # no further derivation. A bare hex string fails with "unrecognized token".
  defp derive(repo_name) do
    key =
      :crypto.mac(:hmac, :sha256, root_secret(), "ashcell-vcs:" <> to_string(repo_name))
      |> Base.encode16(case: :lower)

    ~s|"x'| <> key <> ~s|'"|
  end

  defp root_secret do
    Application.get_env(:vcs, :vault_root_secret) || "vcs-poc-root-secret-not-for-production"
  end
end
