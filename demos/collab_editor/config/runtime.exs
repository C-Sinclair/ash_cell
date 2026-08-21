import Config

# The demo is meant to be run from a checkout with `mix phx.server`, so this file
# only handles the server-in-a-release case and the secret.
if System.get_env("PHX_SERVER") do
  config :collab_editor, CollabEditorWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  config :collab_editor, CollabEditorWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "example.com", port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4000")
    ],
    secret_key_base: secret_key_base
end
