defmodule AtpMcp.Backends.SystemOnTptp do
  @moduledoc false
  @callback list_provers() :: [String.t()]
  @callback query(String.t(), keyword()) :: {:ok, any()} | {:error, any()}
  @callback query_system(String.t(), String.t(), keyword()) ::
              {:ok, any()} | {:error, any()}
  @callback query_selected_systems(String.t(), [String.t()], keyword()) ::
              {:ok, [{String.t(), any()}]} | {:error, any()}
  @callback verify(keyword()) :: :ok | {:error, any()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.Isabelle do
  @moduledoc false
  @callback query(String.t(), keyword()) :: {:ok, any()} | {:error, any()}
  @callback query(String.t(), String.t(), keyword()) :: {:ok, any()} | {:error, any()}
  @callback verify(keyword()) :: :ok | {:error, any()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.LocalExec do
  @moduledoc false
  @callback query(String.t(), keyword()) :: {:ok, any()} | {:error, any()}
  @callback verify(keyword()) :: :ok | {:error, any()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.StarExec do
  @moduledoc false
  @callback query(String.t(), keyword()) :: {:ok, any()} | {:error, any()}
  @callback verify(keyword()) :: :ok | {:error, any()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.Lint do
  @moduledoc false
  @callback analyze(String.t(), keyword()) :: AtpClient.Lint.Report.t()
end

defmodule AtpMcp do
  @moduledoc """
  MCP stdio server wrapping every `AtpClient` backend.

  Started by Claude Code (or any other MCP host) as a child process; reads
  newline-delimited JSON-RPC 2.0 from stdin and writes responses to stdout.

  ## Tools

  Generic, multi-backend (use the unified `AtpClient.Backend` contract):

    * `list_backends`  — enumerate configured backends and their labels;
    * `verify_backend` — probe a backend's configuration / reachability;
    * `query_backend`  — submit a TPTP problem to any backend and get a
      normalized SZS result.

  Backend-specific, kept because they expose surface the unified contract
  does not (system enumeration, multi-system fan-out, hand-written theories,
  source diagnostics):

    * `list_provers`     — `AtpClient.SystemOnTptp.list_provers/0`;
    * `run_prover`       — `AtpClient.SystemOnTptp.query_system/3`;
    * `compare_provers`  — `AtpClient.SystemOnTptp.query_selected_systems/3`;
    * `prove_isabelle`   — `AtpClient.Isabelle.query/3` for hand-written
      theories (the unified `query_backend` with `backend: "isabelle"`
      submits a TPTP problem instead);
    * `lint_problem`     — `AtpClient.Lint.analyze/2`.

  ## Cancellation and progress

  Long-running tool calls (`run_prover`, `compare_provers`,
  `query_backend`, `prove_isabelle`) run inside their own Task in
  `AtpMcp.Runtime`. The MCP host can:

    * Send `notifications/cancelled` carrying the in-flight request id
      to abort a call. The Task is killed, and each `AtpClient` backend
      tears down its upstream work in response (see
      `AtpMcp.Runtime`'s moduledoc for per-backend details). SOTPTP is
      the only backend that cannot truly cancel server-side — its
      `:time_limit_sec` is the only bound on remote work.
    * Set `_meta.progressToken` on `tools/call` to receive periodic
      `notifications/progress` frames while the call is in flight
      (heartbeat every five seconds by default; configurable via
      `:atp_mcp, :heartbeat_ms`).

  ## Forward note: MCP experimental Tasks primitive

  The `2025-11-25` MCP revision incubates a *Tasks* primitive for
  long-running invocations (call-now / fetch-later, with a task handle for
  status polling and deferred result retrieval). That maps almost exactly
  onto ATP workflows. When the primitive stabilises, the long-running
  tools here should grow a task-returning variant and a StarExec-style
  submit/await pair becomes a natural addition.

  ## Protocol

  Speaks MCP revision `2025-11-25`. The `initialize` handshake, `ping`,
  `tools/list`, and `tools/call` are implemented; notifications are
  accepted and silently acknowledged.
  """

  alias AtpClient.Lint.{Diagnostic, Report}

  @protocol_version "2025-11-25"
  @server_version Mix.Project.config()[:version] || "0.0.0"

  @default_backends %{
    "sotptp" => AtpClient.SystemOnTptp,
    "isabelle" => AtpClient.Isabelle,
    "local_exec" => AtpClient.LocalExec,
    "starexec" => AtpClient.StarExec
  }

  # Resolved at call time so tests can inject mocks per backend.
  defp sotptp, do: Application.get_env(:atp_mcp, :sotptp_backend, AtpClient.SystemOnTptp)
  defp isabelle, do: Application.get_env(:atp_mcp, :isabelle_backend, AtpClient.Isabelle)
  defp local_exec, do: Application.get_env(:atp_mcp, :local_exec_backend, AtpClient.LocalExec)
  defp starexec, do: Application.get_env(:atp_mcp, :starexec_backend, AtpClient.StarExec)
  defp lint, do: Application.get_env(:atp_mcp, :lint_backend, AtpClient.Lint)

  defp backend_registry do
    %{
      "sotptp" => sotptp(),
      "isabelle" => isabelle(),
      "local_exec" => local_exec(),
      "starexec" => starexec()
    }
  end

  defp known_backend_names, do: @default_backends |> Map.keys() |> Enum.sort()

  def main(_args \\ []) do
    # Escripts do not start OTP applications automatically; bring up the
    # full atp_client tree (Finch, the Provers agent, etc.).
    Application.ensure_all_started(:atp_client)

    {:ok, _pid} =
      AtpMcp.Runtime.start_link(
        heartbeat_ms: Application.get_env(:atp_mcp, :heartbeat_ms, 5_000)
      )

    :stdio
    |> IO.stream(:line)
    |> Enum.each(&AtpMcp.Runtime.deliver/1)

    # Stdin closed. Wait for in-flight tool tasks to finish so their
    # responses reach stdout before the BEAM exits.
    AtpMcp.Runtime.await_idle()
  end

  @doc """
  Synchronously process one JSON-RPC line and return the response JSON (or
  `nil` for notifications, blank lines, and cancellations). Kept for tests
  and downstream callers that prefer a pure-function entry point.

  `tools/call` runs the work inline — it does not start a Task. For the
  concurrent + cancellable + progress-emitting path, use
  `AtpMcp.Runtime.deliver/1`.
  """
  @spec handle_rpc(String.t()) :: String.t() | nil
  def handle_rpc(line) do
    trimmed = String.trim(line)

    case trimmed do
      "" ->
        nil

      _ ->
        case Jason.decode(trimmed) do
          {:ok, json} -> render_sync(classify(json))
          {:error, _} -> Jason.encode!(parse_error())
        end
    end
  end

  defp render_sync({:reply, response}), do: Jason.encode!(response)

  defp render_sync({:tool_call, id, name, args, _token}),
    do: Jason.encode!(tool_response(id, execute_tool(name, args)))

  defp render_sync({:cancel, _id}), do: nil
  defp render_sync(:noop), do: nil

  @doc """
  Classify a decoded JSON-RPC message. The return value is one of:

    * `{:reply, response}` — synchronous reply, encode and write;
    * `{:tool_call, id, name, args, progress_token}` — start a Task;
    * `{:cancel, id}` — cancel the in-flight Task for `id`;
    * `:noop` — drop (notifications, unknown notifications, etc.).

  Pure: never touches stdout, never mutates state. The runtime owns
  side effects.
  """
  @spec classify(map()) ::
          {:reply, map()}
          | {:tool_call, any(), String.t() | nil, map(), any()}
          | {:cancel, any()}
          | :noop
  def classify(%{"method" => "initialize", "id" => id}) do
    {:reply,
     %{
       jsonrpc: "2.0",
       id: id,
       result: %{
         protocolVersion: @protocol_version,
         capabilities: %{tools: %{}},
         serverInfo: %{name: "atp", version: @server_version}
       }
     }}
  end

  def classify(%{"method" => "ping", "id" => id}) do
    {:reply, %{jsonrpc: "2.0", id: id, result: %{}}}
  end

  def classify(%{"method" => "tools/list", "id" => id}) do
    {:reply, %{jsonrpc: "2.0", id: id, result: %{tools: tool_schemas()}}}
  end

  def classify(%{"method" => "tools/call", "id" => id, "params" => params}) do
    name = Map.get(params, "name")
    args = Map.get(params, "arguments", %{})
    token = get_in(params, ["_meta", "progressToken"])
    {:tool_call, id, name, args, token}
  end

  def classify(%{"method" => "notifications/cancelled", "params" => %{"requestId" => id}}),
    do: {:cancel, id}

  def classify(%{"method" => method})
      when method in ["notifications/initialized", "initialized"],
      do: :noop

  def classify(%{"id" => id}) do
    {:reply, %{jsonrpc: "2.0", id: id, error: %{code: -32_601, message: "Method not found"}}}
  end

  def classify(_), do: :noop

  @doc """
  Run a tool by name. Catches exceptions and returns an `Error: …` string
  in their place, matching the tool-result error convention. Pure with
  respect to stdout — wraps `call_tool/2`.
  """
  @spec execute_tool(String.t() | nil, map()) :: String.t()
  def execute_tool(name, args) when is_binary(name) do
    try do
      call_tool(name, args)
    rescue
      e -> "Error: #{Exception.message(e)}"
    end
  end

  def execute_tool(_name, _args), do: "Error: missing required field 'name'"

  @doc false
  def tool_response(id, content) do
    %{jsonrpc: "2.0", id: id, result: %{content: [%{type: "text", text: content}]}}
  end

  @doc false
  def parse_error do
    %{jsonrpc: "2.0", id: nil, error: %{code: -32_700, message: "Parse error"}}
  end

  # --- Tool implementations ---

  defp call_tool("list_backends", _args) do
    backend_registry()
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn {name, module} -> "#{name}\t#{safe_label(module)}" end)
  end

  defp call_tool("verify_backend", %{"backend" => name} = args) do
    case resolve_backend(name) do
      {:ok, module} ->
        case module.verify(opts_from(args, name)) do
          :ok -> "OK"
          {:error, reason} -> "Error: #{inspect(reason)}"
        end

      {:error, message} ->
        "Error: #{message}"
    end
  end

  defp call_tool("verify_backend", _args), do: "Error: verify_backend requires 'backend'"

  defp call_tool("query_backend", %{"backend" => name, "problem" => problem} = args) do
    case resolve_backend(name) do
      {:ok, module} ->
        case module.query(problem, opts_from(args, name)) do
          {:ok, result} -> format_result(result)
          {:error, reason} -> "Error: #{inspect(reason)}"
        end

      {:error, message} ->
        "Error: #{message}"
    end
  end

  defp call_tool("query_backend", _args) do
    "Error: query_backend requires 'backend' and 'problem'"
  end

  defp call_tool("list_provers", _args) do
    sotptp().list_provers()
    |> Enum.sort()
    |> Enum.join("\n")
  end

  defp call_tool("run_prover", %{"problem" => problem, "system_id" => system_id} = args) do
    raw = Map.get(args, "raw", false)
    opts = [raw: raw] ++ time_limit_opt(args)

    case sotptp().query_system(problem, system_id, opts) do
      {:ok, result} -> format_result(result)
      {:error, reason} -> "Error: #{inspect(reason)}"
    end
  end

  defp call_tool("run_prover", _args) do
    "Error: run_prover requires 'problem' and 'system_id'"
  end

  defp call_tool("compare_provers", %{"problem" => problem, "system_ids" => system_ids} = args) do
    opts = time_limit_opt(args)

    case sotptp().query_selected_systems(problem, system_ids, opts) do
      {:ok, results} ->
        Enum.map_join(results, "\n", fn {system, atp_result} ->
          "#{system}: #{format_atp_result(atp_result)}"
        end)

      {:error, reason} ->
        "Error: #{inspect(reason)}"
    end
  end

  defp call_tool("compare_provers", _args) do
    "Error: compare_provers requires 'problem' and 'system_ids'"
  end

  defp call_tool("prove_isabelle", %{"theory" => theory, "theory_name" => name} = args) do
    raw = Map.get(args, "raw", false)
    opts = [raw: raw] ++ isabelle_opts(args)

    case isabelle().query(theory, name, opts) do
      {:ok, result} -> format_result(result)
      {:error, reason} -> "Error: #{inspect(reason)}"
    end
  end

  defp call_tool("prove_isabelle", _args) do
    "Error: prove_isabelle requires 'theory' and 'theory_name'"
  end

  defp call_tool("lint_problem", %{"problem" => problem} = args) do
    report = lint().analyze(problem, lint_opts(args))
    format_lint_report(report)
  end

  defp call_tool("lint_problem", _args) do
    "Error: lint_problem requires 'problem'"
  end

  defp call_tool(name, _args), do: "Unknown tool: #{name}"

  # --- Helpers ---

  defp resolve_backend(name) when is_binary(name) do
    case Map.fetch(backend_registry(), name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error,
         "unknown backend #{inspect(name)}; known: " <> Enum.join(known_backend_names(), ", ")}
    end
  end

  defp resolve_backend(_), do: {:error, "backend must be a string"}

  defp safe_label(module) do
    _ = Code.ensure_loaded(module)

    if function_exported?(module, :label, 0) do
      module.label()
    else
      Atom.to_string(module)
    end
  end

  # Strip MCP-protocol keys before forwarding the remainder as a keyword list
  # of per-call backend overrides. Each backend reads what it understands.
  @protocol_keys ~w(backend problem theory theory_name system_id system_ids)
  defp opts_from(args, "sotptp"), do: opts_from_filtered(args, [:time_limit_sec, :raw, :url])

  defp opts_from(args, "isabelle"),
    do:
      opts_from_filtered(args, [
        :session,
        :host,
        :port,
        :password,
        :local_dir,
        :isabelle_dir,
        :use_theories_timeout_ms,
        :raw
      ])
      |> rename_key(:timeout_ms, :use_theories_timeout_ms, args)

  defp opts_from(args, "local_exec"),
    do: opts_from_filtered(args, [:binary, :args, :cpu_timeout_s, :wall_timeout_ms, :raw])

  defp opts_from(args, "starexec"),
    do:
      opts_from_filtered(args, [
        :base_url,
        :username,
        :password,
        :request_timeout_ms,
        :poll_interval_ms,
        :timeout_ms,
        :raw
      ])

  defp opts_from(args, _),
    do: opts_from_filtered(args, [:time_limit_sec, :raw])

  defp opts_from_filtered(args, allowed) do
    args
    |> Map.drop(@protocol_keys)
    |> Enum.reduce([], fn {key, value}, acc ->
      atom = safe_to_atom(key)

      cond do
        atom in allowed -> [{atom, value} | acc]
        true -> acc
      end
    end)
  end

  defp rename_key(opts, from, to, args) do
    case Map.fetch(args, Atom.to_string(from)) do
      {:ok, value} -> Keyword.put(opts, to, value)
      :error -> opts
    end
  end

  defp safe_to_atom(key) when is_atom(key), do: key

  defp safe_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp time_limit_opt(%{"time_limit_sec" => t}) when is_integer(t), do: [time_limit_sec: t]
  defp time_limit_opt(_), do: []

  defp isabelle_opts(args), do: opts_from(args, "isabelle")

  defp lint_opts(%{"backends" => backends}) when is_list(backends) do
    parsed =
      backends
      |> Enum.map(&parse_lint_backend/1)
      |> Enum.reject(&is_nil/1)

    case parsed do
      [] -> []
      list -> [backends: list]
    end
  end

  defp lint_opts(_), do: []

  defp parse_lint_backend("local"), do: :local
  defp parse_lint_backend("tptp4x"), do: :tptp4x
  defp parse_lint_backend(_), do: nil

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
  defp format_result(map) when is_map(map), do: inspect(map, pretty: true, limit: :infinity)
  defp format_result(other), do: inspect(other)

  defp format_lint_report(%Report{diagnostics: [], symbols: []}), do: "OK (no diagnostics)"

  defp format_lint_report(%Report{diagnostics: [], symbols: syms}),
    do: "OK (no diagnostics)\n\n" <> format_symbols(syms)

  defp format_lint_report(%Report{diagnostics: diags, symbols: syms}) do
    diag_text = Enum.map_join(diags, "\n", &format_diagnostic/1)

    case syms do
      [] -> diag_text
      _ -> diag_text <> "\n\n" <> format_symbols(syms)
    end
  end

  defp format_diagnostic(%Diagnostic{
         line: line,
         column: column,
         severity: severity,
         message: message,
         source: source
       }) do
    source_tag = if source, do: " (#{source})", else: ""
    "#{line}:#{column} [#{severity}]#{source_tag} #{message}"
  end

  defp format_symbols(symbols) do
    body =
      Enum.map_join(symbols, "\n", fn sym ->
        type = if sym.type, do: " : #{sym.type}", else: ""
        "  #{sym.name}#{type} (#{sym.kind} at #{sym.line}:#{sym.column})"
      end)

    "Symbols:\n" <> body
  end

  # --- MCP tool schemas ---

  @backend_enum ~w(sotptp isabelle local_exec starexec)

  defp tool_schemas do
    [
      %{
        name: "list_backends",
        description:
          "List the AtpClient backends this MCP server exposes (sotptp, isabelle, local_exec, starexec) and their human-readable labels.",
        inputSchema: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "verify_backend",
        description: """
        Probe a backend's configuration and reachability. Returns "OK" if the
        backend is wired up correctly, otherwise an error describing what is
        missing or unreachable.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            backend: %{
              type: "string",
              enum: @backend_enum,
              description: "Backend to probe"
            }
          },
          required: ["backend"],
          additionalProperties: true
        }
      },
      %{
        name: "query_backend",
        description: """
        Run a TPTP-format problem through any AtpClient backend and return the
        normalized SZS-style result (Theorem, Satisfiable, Timeout, …). The
        unified `AtpClient.Backend.query/2` entry point — each backend hides
        its ceremony (session, prover selection, theory bookkeeping) behind
        this call.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            backend: %{
              type: "string",
              enum: @backend_enum,
              description: "Which backend to run on"
            },
            problem: %{type: "string", description: "TPTP problem text"},
            time_limit_sec: %{
              type: "integer",
              description: "Time limit for backends that honour it (sotptp)"
            },
            raw: %{type: "boolean", description: "Return raw backend output where supported"}
          },
          required: ["backend", "problem"],
          additionalProperties: true
        }
      },
      %{
        name: "list_provers",
        description: "List every theorem prover system available on SystemOnTPTP.",
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
        Submit a TPTP problem to multiple SystemOnTPTP provers simultaneously
        and report SZS results side-by-side. Useful for cross-checking or
        finding the fastest prover for a problem class.
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
      },
      %{
        name: "prove_isabelle",
        description: """
        Submit a hand-written Isabelle/HOL theory to a configured Isabelle
        server. The theory text is written into the configured shared
        directory and processed via `use_theories`. For TPTP/THF problems use
        `query_backend` with `backend: "isabelle"` instead — that routes
        through `query_tptp`.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            theory: %{type: "string", description: "Isabelle theory text"},
            theory_name: %{
              type: "string",
              description: "Theory name (also used as the .thy filename)"
            },
            session: %{type: "string", description: "Override the Isabelle session name"},
            host: %{type: "string", description: "Override the Isabelle host"},
            port: %{type: "integer", description: "Override the Isabelle port"},
            timeout_ms: %{
              type: "integer",
              description: "Overall use_theories timeout in milliseconds"
            },
            raw: %{type: "boolean", description: "Return raw use_theories payload"}
          },
          required: ["theory", "theory_name"]
        }
      },
      %{
        name: "lint_problem",
        description: """
        Run syntax and type diagnostics on a TPTP problem. By default combines
        the in-process structural checker with TPTP4X on SystemOnTPTP; pass
        `backends: ["local"]` for the cheap pass only.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            problem: %{type: "string", description: "TPTP problem text"},
            backends: %{
              type: "array",
              items: %{type: "string", enum: ["local", "tptp4x"]},
              description: "Which lint backends to run (default: both)"
            }
          },
          required: ["problem"]
        }
      }
    ]
  end
end
