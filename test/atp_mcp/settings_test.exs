defmodule AtpMcp.SettingsTest do
  # Reads and writes the global application env and environment variables.
  use ExUnit.Case, async: false

  alias AtpMcp.Settings

  @moduletag :tmp_dir

  setup do
    saved = Application.get_all_env(:atp_client)
    saved_var = System.get_env("ATP_MCP_CONFIG")

    on_exit(fn ->
      Enum.each(Application.get_all_env(:atp_client), fn {key, _} ->
        Application.delete_env(:atp_client, key)
      end)

      Application.put_all_env(atp_client: saved)
      restore_var(saved_var)
    end)

    System.delete_env("ATP_MCP_CONFIG")
    :ok
  end

  defp restore_var(nil), do: System.delete_env("ATP_MCP_CONFIG")
  defp restore_var(value), do: System.put_env("ATP_MCP_CONFIG", value)

  defp write_config(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "import Config\n" <> body)
    path
  end

  test "--config loads the file into the application env", %{tmp_dir: dir} do
    path =
      write_config(dir, "a.exs", ~s|config :atp_client, :sotptp, default_system: "Vampire"\n|)

    assert Settings.load(path) == {:ok, path}
    assert Application.get_env(:atp_client, :sotptp)[:default_system] == "Vampire"
  end

  test "the file is evaluated at load time, so it can read the environment",
       %{tmp_dir: dir} do
    System.put_env("ATP_MCP_TEST_SECRET", "hunter2")
    on_exit(fn -> System.delete_env("ATP_MCP_TEST_SECRET") end)

    path =
      write_config(
        dir,
        "a.exs",
        ~s|config :atp_client, :starexec, password: System.get_env("ATP_MCP_TEST_SECRET")\n|
      )

    {:ok, _} = Settings.load(path)
    assert Application.get_env(:atp_client, :starexec)[:password] == "hunter2"
  end

  test "ATP_MCP_CONFIG is used when no flag is given", %{tmp_dir: dir} do
    path = write_config(dir, "env.exs", ~s|config :atp_client, :sotptp, default_system: "E"\n|)
    System.put_env("ATP_MCP_CONFIG", path)

    assert Settings.load(nil) == {:ok, path}
  end

  test "the flag wins over ATP_MCP_CONFIG", %{tmp_dir: dir} do
    flag = write_config(dir, "flag.exs", "")
    System.put_env("ATP_MCP_CONFIG", write_config(dir, "env.exs", ""))

    assert Settings.load(flag) == {:ok, flag}
  end

  test "an explicitly named file that does not exist is an error", %{tmp_dir: dir} do
    missing = Path.join(dir, "nope.exs")
    assert {:error, "config file not found: " <> _} = Settings.load(missing)

    System.put_env("ATP_MCP_CONFIG", missing)
    assert {:error, "config file not found: " <> _} = Settings.load(nil)
  end

  test "a file that does not evaluate is an error naming it", %{tmp_dir: dir} do
    path = write_config(dir, "bad.exs", "config :atp_client, :sotptp, [\n")
    assert {:error, "could not read " <> rest} = Settings.load(path)
    assert rest =~ "bad.exs"
  end

  describe "with eprover on PATH" do
    setup %{tmp_dir: dir} do
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "eprover"), "#!/bin/sh\n")
      File.chmod!(Path.join(bin, "eprover"), 0o755)

      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)
      on_exit(fn -> System.put_env("PATH", path) end)
      :ok
    end

    test "local_exec defaults to E" do
      Application.delete_env(:atp_client, :local_exec)
      {:ok, _} = Settings.load(nil)

      local_exec = Application.get_env(:atp_client, :local_exec)
      assert local_exec[:binary] == "eprover"
      assert "--auto" in local_exec[:args]
    end

    test "a configured binary is left alone", %{tmp_dir: dir} do
      path = write_config(dir, "v.exs", ~s|config :atp_client, :local_exec, binary: "vampire"\n|)
      {:ok, _} = Settings.load(path)

      assert Application.get_env(:atp_client, :local_exec) == [binary: "vampire"]
    end

    test "configured keys win over the E defaults", %{tmp_dir: dir} do
      path = write_config(dir, "c.exs", ~s|config :atp_client, :local_exec, cpu_timeout_s: 5\n|)
      {:ok, _} = Settings.load(path)

      local_exec = Application.get_env(:atp_client, :local_exec)
      assert local_exec[:binary] == "eprover"
      assert local_exec[:cpu_timeout_s] == 5
    end
  end

  test "without a flag, variable, or ./atp_mcp.exs there is no file" do
    # The test suite runs from the project root, which has no atp_mcp.exs.
    refute File.exists?("atp_mcp.exs")
    assert Settings.load(nil) == {:ok, nil}
  end
end
