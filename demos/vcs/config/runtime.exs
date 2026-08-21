import Config

# Env overrides so a second server can be started on another port, against another cell
# directory, without editing config. The end-to-end script relies on both.
if dir = System.get_env("VCS_CELL_DIR") do
  config :vcs, :cell_dir, dir
end

if port = System.get_env("PORT") do
  config :vcs, VcsWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)],
    server: true
end
