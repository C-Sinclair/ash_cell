File.rm_rf!(Application.get_env(:vcs, :cell_dir, "priv/test_cells"))
File.mkdir_p!(Application.get_env(:vcs, :cell_dir, "priv/test_cells"))

ExUnit.start(exclude: [:minio])
