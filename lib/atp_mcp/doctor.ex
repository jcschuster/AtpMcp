defmodule AtpMcp.Doctor do
  @moduledoc """
  `atp_mcp doctor [BACKEND…]`: for each backend, the settings it resolved
  to and whether its `verify/1` passes.

  Run it in the same environment the MCP host runs the server in — the same
  working directory, `--config`, and environment variables — since that is
  where the settings come from. Passwords are shown only as set or unset.
  """

  @shown %{
    "sotptp" => {:sotptp, [:url, :default_system, :default_time_limit_sec]},
    "local_exec" => {:local_exec, [:binary, :args, :cpu_timeout_s]},
    "isabelle" => {:isabelle, [:host, :port, :password, :session, :local_dir]},
    "starexec" => {:starexec, [:base_url, :username, :password]}
  }

  @doc """
  Prints the report for `names` (every backend when empty) to stdout and
  returns `:ok` when every check passed, `:error` otherwise.
  """
  @spec run([String.t()], %{String.t() => module()}, Path.t() | nil, String.t()) :: :ok | :error
  def run(names, backends, config_path, version) do
    IO.puts("atp_mcp #{version}")
    IO.puts("config file: #{config_path || "none (defaults only)"}")

    names
    |> selected(backends)
    |> Enum.map(fn name -> check(name, Map.fetch(backends, name)) end)
    |> Enum.all?(&(&1 == :ok))
    |> verdict()
  end

  defp selected([], backends), do: backends |> Map.keys() |> Enum.sort()
  defp selected(names, _backends), do: names

  defp verdict(true), do: :ok
  defp verdict(false), do: :error

  defp check(name, :error) do
    IO.puts("\n#{name}\n  check: unknown backend")
    :error
  end

  defp check(name, {:ok, module}) do
    IO.puts("\n#{name} - #{module.label()}")
    Enum.each(settings(name), &IO.puts/1)
    outcome = verify(module)
    IO.puts("  check: #{describe(outcome)}")
    outcome
  end

  defp settings(name) do
    {backend, keys} = Map.fetch!(@shown, name)
    resolved = AtpClient.Config.get(backend)
    Enum.map(keys, fn key -> "  #{key}: #{show(key, Keyword.get(resolved, key))}" end)
  end

  defp show(_key, nil), do: "(unset)"
  defp show(:password, _value), do: "(set)"
  defp show(_key, value), do: inspect(value)

  # Unconfigured backends raise rather than return an error; either way it
  # is a finding to report, not a reason to stop checking the others.
  defp verify(module) do
    module.verify([])
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp describe(:ok), do: "OK"
  defp describe({:error, {:config_error, message}}), do: "Error: #{first_line(message)}"
  defp describe({:error, {:no_isabelle_server, message}}), do: "Error: #{message}"
  defp describe({:error, message}) when is_binary(message), do: "Error: #{first_line(message)}"
  defp describe({:error, reason}), do: "Error: #{inspect(reason)}"

  defp first_line(message), do: message |> String.split("\n", trim: true) |> List.first()
end
