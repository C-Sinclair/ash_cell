defmodule VcsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :vcs

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    # Whole-object JSON means a push body is roughly the size of the objects it carries.
    length: 64_000_000
  )

  plug(VcsWeb.Router)
end
