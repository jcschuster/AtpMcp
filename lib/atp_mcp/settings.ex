defmodule AtpMcp.Settings do
  @moduledoc """
  Runtime configuration for the escript.

  An escript carries the configuration it was built with and never reads a
  project's `config/*.exs`. `load/1` closes that gap: it evaluates a config
  file at startup, then fills in defaults so the server is useful with no
  file at all.

  ## The config file

  The first of:

    1. the `--config PATH` command-line flag;
    2. the `ATP_MCP_CONFIG` environment variable;
    3. `atp_mcp.exs` in the working directory.

  A file named by (1) or (2) must exist; a missing `atp_mcp.exs` is fine.
  The file is ordinary `Config`, evaluated when the server starts, so
  `System.get_env/1` is the place for secrets:

      import Config

      config :atp_client, :starexec,
        base_url: "https://starexec.example.org/starexec",
        username: System.get_env("STAREXEC_USER"),
        password: System.get_env("STAREXEC_PASS")

  ## Defaults

  Applied after the file, only to keys it left unset:

    * `local_exec` runs E (`eprover --auto --tstp-format`, 30 s CPU) when
      `eprover` is on `PATH`.

  Everything else needs no default here: SystemOnTPTP works unconfigured
  (AtpClient defaults to tptp.org and the latest `E`), and with no Isabelle
  password configured `AtpMcp.IsabelleSession` starts a local server itself.
  """

  @default_file "atp_mcp.exs"
  @env_var "ATP_MCP_CONFIG"

  @eprover_defaults [
    binary: "eprover",
    args: ["--auto", "--tstp-format", "--cpu-limit=30"],
    cpu_timeout_s: 30
  ]

  @doc """
  Loads the config file, if any, into the application environment and
  applies the defaults. Returns the path of the file that was read, or
  `nil` when there was none.
  """
  @spec load(Path.t() | nil) :: {:ok, Path.t() | nil} | {:error, String.t()}
  def load(flag_path) do
    with {:ok, path} <- locate(flag_path, System.get_env(@env_var)),
         :ok <- read(path) do
      apply_defaults(System.find_executable("eprover"))
      {:ok, path}
    end
  end

  defp locate(path, _env) when is_binary(path), do: explicit(path)
  defp locate(nil, env) when env not in [nil, ""], do: explicit(env)

  defp locate(nil, _env) do
    case File.regular?(@default_file) do
      true -> {:ok, Path.expand(@default_file)}
      false -> {:ok, nil}
    end
  end

  defp explicit(path) do
    case File.regular?(path) do
      true -> {:ok, Path.expand(path)}
      false -> {:error, "config file not found: #{path}"}
    end
  end

  # `persistent: true` so that loading `:atp_client` afterwards does not
  # reset these keys to the values in its `.app` file.
  defp read(nil), do: :ok

  defp read(path) do
    path
    |> Config.Reader.read!()
    |> Application.put_all_env(persistent: true)
  rescue
    e -> {:error, "could not read #{path}: #{Exception.message(e)}"}
  end

  defp apply_defaults(nil), do: :ok

  defp apply_defaults(_eprover) do
    configured = Application.get_env(:atp_client, :local_exec, [])

    case Keyword.has_key?(configured, :binary) do
      true ->
        :ok

      false ->
        merged = Keyword.merge(@eprover_defaults, configured)
        Application.put_env(:atp_client, :local_exec, merged, persistent: true)
    end
  end
end
