defmodule AtpMcp.AtpBehaviour do
  @moduledoc false
  @callback list_provers() :: [String.t()]
  @callback query_system(String.t(), String.t(), keyword()) :: {:ok, any()} | {:error, any()}
  @callback query_selected_systems(String.t(), [String.t()], keyword()) ::
              {:ok, [{String.t(), any()}]} | {:error, any()}
end

defmodule AtpMcp do
  @moduledoc false

  # MCP stdio server wrapping AtpClient.SystemOnTptp.
  # Started by Claude Code as a child process; reads newline-delimited
  # JSON-RPC 2.0 from stdin and writes responses to stdout.

  # Resolved at call time so tests can swap the implementation without needing
  # a compile-time config.
  defp atp_client, do: Application.get_env(:atp_mcp, :atp_client, AtpClient.SystemOnTptp)

  def main(_args \\ []) do
    # Escripts do not start OTP applications automatically; start the full
    # atp_client tree (which brings up Finch and the Provers agent).
    Application.ensure_all_started(:atp_client)

    :stdio
    |> IO.stream(:line)
    |> Enum.each(&process_line/1)
  end

  # Parses one JSON-RPC line and returns the encoded response string, or nil
  # for notifications and blank lines. Public so the test suite can drive it
  # directly without capturing stdio.
  @doc false
  def handle_rpc(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      case Jason.decode(trimmed) do
        {:ok, json} ->
          json
          |> dispatch()
          |> case do
            nil -> nil
            response -> Jason.encode!(response)
          end

        {:error, _} ->
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: nil,
            error: %{code: -32_700, message: "Parse error"}
          })
      end
    end
  end

  defp process_line(line) do
    case handle_rpc(line) do
      nil -> :ok
      response -> IO.puts(response)
    end
  end

  # --- JSON-RPC dispatch ---

  defp dispatch(%{"method" => "initialize", "id" => id}) do
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        protocolVersion: "2024-11-05",
        capabilities: %{tools: %{}},
        serverInfo: %{name: "atp", version: "0.1.0"}
      }
    }
  end

  defp dispatch(%{"method" => "ping", "id" => id}) do
    %{jsonrpc: "2.0", id: id, result: %{}}
  end

  defp dispatch(%{"method" => "tools/list", "id" => id}) do
    %{jsonrpc: "2.0", id: id, result: %{tools: tool_schemas()}}
  end

  defp dispatch(%{"method" => "tools/call", "id" => id, "params" => params}) do
    name = Map.get(params, "name")
    # "arguments" is optional per the MCP spec; default to an empty map so
    # tools with no parameters (e.g. list_provers) work without the key.
    args = Map.get(params, "arguments", %{})

    content =
      if is_binary(name) do
        try do
          call_tool(name, args)
        rescue
          e -> "Error: #{Exception.message(e)}"
        end
      else
        "Error: missing required field 'name'"
      end

    %{
      jsonrpc: "2.0",
      id: id,
      result: %{content: [%{type: "text", text: content}]}
    }
  end

  # Notifications have no id and need no response.
  defp dispatch(%{"method" => method}) when method in ["notifications/initialized", "initialized"],
    do: nil

  defp dispatch(%{"id" => id}) do
    %{jsonrpc: "2.0", id: id, error: %{code: -32_601, message: "Method not found"}}
  end

  defp dispatch(_), do: nil

  # --- Tool implementations ---

  defp call_tool("list_provers", _args) do
    atp_client().list_provers()
    |> Enum.sort()
    |> Enum.join("\n")
  end

  defp call_tool("run_prover", %{"problem" => problem, "system_id" => system_id} = args) do
    raw = Map.get(args, "raw", false)
    opts = [raw: raw] ++ time_limit_opt(args)

    case atp_client().query_system(problem, system_id, opts) do
      {:ok, result} -> format_result(result)
      {:error, reason} -> "Error: #{inspect(reason)}"
    end
  end

  defp call_tool("run_prover", _args) do
    "Error: run_prover requires 'problem' and 'system_id'"
  end

  defp call_tool("compare_provers", %{"problem" => problem, "system_ids" => system_ids} = args) do
    opts = time_limit_opt(args)

    case atp_client().query_selected_systems(problem, system_ids, opts) do
      {:ok, results} ->
        results
        |> Enum.map_join("\n", fn {system, atp_result} ->
          "#{system}: #{format_atp_result(atp_result)}"
        end)

      {:error, reason} ->
        "Error: #{inspect(reason)}"
    end
  end

  defp call_tool("compare_provers", _args) do
    "Error: compare_provers requires 'problem' and 'system_ids'"
  end

  defp call_tool(name, _args), do: "Unknown tool: #{name}"

  # --- Helpers ---

  defp time_limit_opt(%{"time_limit_sec" => t}) when is_integer(t), do: [time_limit_sec: t]
  defp time_limit_opt(_), do: []

  defp format_atp_result({:ok, status}), do: format_result(status)
  defp format_atp_result({:error, reason}), do: "error(#{inspect(reason)})"

  defp format_result(:thm), do: "Theorem"
  defp format_result(:sat), do: "Satisfiable"
  defp format_result(:csat), do: "Countersatisfiable"
  defp format_result(:timeout), do: "Timeout"
  defp format_result(:out_of_resources), do: "Out of resources"
  defp format_result(:gave_up), do: "Gave up"
  defp format_result(:interrupted), do: "Interrupted"
  defp format_result(text) when is_binary(text), do: text
  defp format_result(other), do: inspect(other)

  # --- MCP tool schemas ---

  defp tool_schemas do
    [
      %{
        name: "list_provers",
        description: "List all theorem prover systems available on SystemOnTPTP",
        inputSchema: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "run_prover",
        description: """
        Submit a TPTP-format problem to a specific prover on SystemOnTPTP.
        Returns the SZS status (Theorem, Satisfiable, Timeout, …) or raw output.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            problem: %{type: "string", description: "TPTP problem text"},
            system_id: %{type: "string", description: "Prover ID from list_provers"},
            time_limit_sec: %{type: "integer", description: "Time limit in seconds"},
            raw: %{type: "boolean", description: "Return raw prover output"}
          },
          required: ["problem", "system_id"]
        }
      },
      %{
        name: "compare_provers",
        description: """
        Submit a TPTP problem to multiple provers simultaneously and compare SZS results.
        Useful for cross-checking or finding the fastest prover for a problem class.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            problem: %{type: "string", description: "TPTP problem text"},
            system_ids: %{
              type: "array",
              items: %{type: "string"},
              description: "List of prover IDs to compare"
            },
            time_limit_sec: %{type: "integer", description: "Time limit per prover in seconds"}
          },
          required: ["problem", "system_ids"]
        }
      }
    ]
  end
end
