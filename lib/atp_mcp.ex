defmodule AtpMcp do
  @moduledoc """
  MCP stdio server wrapping every `AtpClient` backend.

  Started by Claude Code (or any other MCP host) as a child process; reads
  newline-delimited JSON-RPC 2.0 from stdin and writes responses to stdout.

  ## Tools

  Generic, multi-backend (use the unified `AtpClient.Backend` contract):

    * `list_backends`  — enumerate configured backends and their labels;
    * `describe_szs`   — return the SZS Ontology reference so an agent can
      look up what each verdict (Theorem, CounterSatisfiable, ResourceOut,
      …) means without leaving the MCP session;
    * `verify_backend` — probe a backend's configuration / reachability;
    * `query_backend`  — submit a TPTP problem to any backend and get an
      SZS Ontology verdict.

  Backend-specific, kept because they expose surface the unified contract
  does not (system enumeration, multi-system fan-out, hand-written theories,
  source diagnostics):

    * `list_provers`     — `AtpClient.SystemOnTptp.list_provers/0`;
    * `run_prover`       — `AtpClient.SystemOnTptp.query_system/3`;
    * `compare_provers`  — `AtpClient.SystemOnTptp.query_selected_systems/3`;
    * `prove_isabelle`   — `AtpClient.Isabelle.prove_theory/4` for hand-written
      theories (the unified `query_backend` with `backend: "isabelle"`
      submits a TPTP problem instead);
    * `lint_problem`     — `Tptp.analyze/2` locally, plus
      `AtpClient.Analyzer.Tptp4x` remotely.

  ## Cancellation and progress

  Long-running tool calls (`run_prover`, `compare_provers`,
  `query_backend`, `prove_isabelle`) run inside their own Task in
  `AtpMcp.Runtime`. The MCP host can:

    * Send `notifications/cancelled` carrying the in-flight request id
      to abort a call. The Task is killed, and each `AtpClient` backend
      tears down its upstream work in response (see
      `AtpMcp.Runtime`'s moduledoc for per-backend details). SOTPTP
      and the shared Isabelle session cannot truly cancel server-side
      — their configured timeouts are the only bound on remote work.
    * Set `_meta.progressToken` on `tools/call` to receive periodic
      `notifications/progress` frames while the call is in flight
      (heartbeat every five seconds by default; configurable via
      `:atp_mcp, :heartbeat_ms`).

  ## Isabelle session lifetime

  All isabelle traffic (`prove_isabelle` and `query_backend` with
  `backend: "isabelle"`) is routed through `AtpMcp.IsabelleSession`,
  which holds a single long-lived `AtpClient.Isabelle` session for
  the lifetime of the MCP server. The first call pays the `HOL`
  session-start cost; subsequent calls reuse it. The session is
  configured from application env only — per-call `session` / `host`
  / `port` / `password` overrides are not accepted. With no password
  configured it starts (or reuses) a local resident server; see
  `AtpMcp.IsabelleSession`.

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

  alias AtpClient.Result
  alias Tptp.{Analysis, Diagnostic}
  alias Tptp.Szs.Ontology

  @protocol_version "2025-11-25"
  @server_version Mix.Project.config()[:version]

  @default_backends %{
    "sotptp" => AtpClient.SystemOnTptp,
    "isabelle" => AtpMcp.IsabelleSession,
    "local_exec" => AtpClient.LocalExec,
    "starexec" => AtpClient.StarExec
  }

  @protocol_keys ~w(backend problem theory theory_name system_id system_ids)
  @backend_enum Map.keys(@default_backends)

  # Resolved at call time so tests can inject mocks.
  defp backends, do: Application.get_env(:atp_mcp, :backends, @default_backends)
  defp tptp4x, do: Application.get_env(:atp_mcp, :tptp4x, AtpClient.Analyzer.Tptp4x)

  defp sotptp, do: Map.fetch!(backends(), "sotptp")
  defp isabelle, do: Map.fetch!(backends(), "isabelle")

  # --- Command line ---

  @usage """
  Usage: atp_mcp [--config PATH]            serve MCP over stdio
         atp_mcp doctor [BACKEND...]        check settings and reachability
         atp_mcp --version | --help

  The config file is the first of: --config PATH, $ATP_MCP_CONFIG,
  ./atp_mcp.exs. Backends: #{Enum.join(@backend_enum, ", ")}.
  """

  def main(args \\ []) do
    case OptionParser.parse(args, strict: [config: :string, help: :boolean, version: :boolean]) do
      {opts, argv, []} -> command(Map.new(opts), argv)
      {_opts, _argv, [{flag, _} | _]} -> fail("unknown option #{flag}\n\n" <> @usage)
    end
  end

  defp command(%{help: true}, _argv), do: IO.write(@usage)
  defp command(%{version: true}, _argv), do: IO.puts(@server_version)
  defp command(opts, []), do: opts |> boot() |> serve()

  defp command(opts, ["doctor" | names]) do
    case AtpMcp.Doctor.run(names, backends(), boot(opts), @server_version) do
      :ok -> :ok
      :error -> System.halt(1)
    end
  end

  defp command(_opts, [other | _]), do: fail("unknown command #{other}\n\n" <> @usage)

  # Loads the config file and starts what every command needs. Returns the
  # path of the config file read, if any.
  defp boot(opts) do
    case AtpMcp.Settings.load(opts[:config]) do
      {:ok, config_path} ->
        # Escripts do not start OTP applications automatically; bring up the
        # full atp_client tree (Finch, the Provers agent, etc.).
        {:ok, _} = Application.ensure_all_started(:atp_client)

        # Long-lived Isabelle session shared across every isabelle call.
        # Opened lazily on first use so an unreachable Isabelle server does
        # not block the MCP server from starting or from serving the other
        # backends. Supervised rather than linked directly to main: a crash
        # in the session must never take the other backends' tools down
        # with it.
        {:ok, _} =
          Supervisor.start_link([AtpMcp.IsabelleSession],
            strategy: :one_for_one,
            name: AtpMcp.Supervisor
          )

        config_path

      {:error, message} ->
        fail(message)
    end
  end

  defp serve(_config_path) do
    :ok = :io.setopts(:standard_io, encoding: :latin1)

    {:ok, _pid} =
      AtpMcp.Runtime.start_link(heartbeat_ms: Application.get_env(:atp_mcp, :heartbeat_ms, 5_000))

    :stdio
    |> IO.binstream(:line)
    |> Enum.each(&AtpMcp.Runtime.deliver/1)

    AtpMcp.Runtime.await_idle()
  end

  # stderr, so that an MCP host shows the message in its server log.
  @spec fail(String.t()) :: no_return()
  defp fail(message) do
    IO.puts(:stderr, "atp_mcp: #{message}")
    System.halt(2)
  end

  # --- JSON-RPC framing ---

  @doc """
  Parse one JSON-RPC line and return the encoded response, or `nil` for
  notifications and blank lines. Provided for tests that drive the
  protocol synchronously without spinning up `AtpMcp.Runtime`.
  """
  @spec handle_rpc(String.t()) :: String.t() | nil
  def handle_rpc(line) do
    case String.trim(line) do
      "" ->
        nil

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, json} -> render_sync(classify(json))
          {:error, _} -> Jason.encode!(parse_error())
        end
    end
  end

  defp render_sync({:reply, response}), do: Jason.encode!(response)

  defp render_sync({:tool_call, id, name, args, _token}) do
    Jason.encode!(tool_response(id, execute_tool(name, args)))
  end

  defp render_sync({:cancel, _id}), do: nil
  defp render_sync(:noop), do: nil

  @doc false
  @spec parse_error() :: map()
  def parse_error do
    %{jsonrpc: "2.0", id: nil, error: %{code: -32_700, message: "Parse error"}}
  end

  # --- JSON-RPC classification ---

  @doc """
  Decide what to do with one decoded JSON-RPC message. Pure: returns a
  tag that `handle_rpc/1` (synchronous) and `AtpMcp.Runtime`
  (asynchronous) interpret in their own way.
  """
  @spec classify(map()) ::
          {:reply, map()}
          | {:tool_call, term(), String.t() | nil, map(), term() | nil}
          | {:cancel, term()}
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

  @typedoc """
  Outcome of a tool call: the text to render, tagged with whether it
  represents a failure. `:error` results are reported to the client with
  `isError: true` alongside the usual `Error: …` text.
  """
  @type tool_result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Run a tool by name. Catches exceptions and returns them as `{:error,
  "Error: …"}`, matching the tool-result error convention.
  """
  @spec execute_tool(String.t() | nil, map()) :: tool_result()
  def execute_tool(name, args) when is_binary(name) do
    call_tool(name, args)
  rescue
    e -> {:error, "Error: #{Exception.message(e)}"}
  end

  def execute_tool(_name, _args), do: {:error, "Error: missing required field 'name'"}

  @doc false
  @spec tool_response(term(), tool_result()) :: map()
  def tool_response(id, {:ok, content}) do
    %{jsonrpc: "2.0", id: id, result: %{content: [%{type: "text", text: content}]}}
  end

  # MCP reports tool-level failures in-band: a normal result carrying
  # isError, not a JSON-RPC error (those are reserved for protocol faults).
  def tool_response(id, {:error, content}) do
    %{jsonrpc: "2.0", id: id, result: %{content: [%{type: "text", text: content}], isError: true}}
  end

  # --- Tool implementations ---

  defp call_tool("list_backends", _args) do
    {:ok,
     backends()
     |> Enum.sort_by(fn {name, _} -> name end)
     |> Enum.map_join("\n", fn {name, module} -> "#{name}\t#{module.label()}" end)}
  end

  defp call_tool("describe_szs", _args), do: {:ok, szs_ontology_text()}

  defp call_tool("verify_backend", %{"backend" => name} = args) do
    case resolve_backend(name) do
      {:ok, module} ->
        case module.verify(opts_from(args, name)) do
          :ok -> {:ok, "OK"}
          {:error, reason} -> {:error, "Error: #{inspect(reason)}"}
        end

      {:error, message} ->
        {:error, "Error: #{message}"}
    end
  end

  defp call_tool("verify_backend", _args),
    do: {:error, "Error: verify_backend requires 'backend'"}

  defp call_tool("query_backend", %{"backend" => name, "problem" => problem} = args) do
    case resolve_backend(name) do
      {:ok, module} -> render(module.query(problem, opts_from(args, name)), args)
      {:error, message} -> {:error, "Error: #{message}"}
    end
  end

  defp call_tool("query_backend", _args) do
    {:error, "Error: query_backend requires 'backend' and 'problem'"}
  end

  defp call_tool("list_provers", _args) do
    {:ok,
     sotptp().list_provers()
     |> Enum.sort()
     |> Enum.join("\n")}
  end

  defp call_tool("run_prover", %{"problem" => problem, "system_id" => system_id} = args) do
    render(sotptp().query_system(problem, system_id, time_limit_opt(args)), args)
  end

  defp call_tool("run_prover", _args) do
    {:error, "Error: run_prover requires 'problem' and 'system_id'"}
  end

  defp call_tool("compare_provers", %{"problem" => problem, "system_ids" => system_ids} = args)
       when is_list(system_ids) do
    case sotptp().query_selected_systems(problem, system_ids, time_limit_opt(args)) do
      {:ok, results} -> {:ok, format_compare_report(results, system_ids)}
      {:error, reason} -> {:error, "Error: #{describe_failure(reason)}"}
    end
  end

  defp call_tool("compare_provers", _args) do
    {:error, "Error: compare_provers requires 'problem' and 'system_ids'"}
  end

  defp call_tool("prove_isabelle", %{"theory" => theory, "theory_name" => name} = args) do
    render(isabelle().prove_theory(theory, name, opts_from(args, "isabelle")), args)
  end

  defp call_tool("prove_isabelle", _args) do
    {:error, "Error: prove_isabelle requires 'theory' and 'theory_name'"}
  end

  defp call_tool("lint_problem", %{"problem" => problem} = args) do
    analysis = problem |> Tptp.analyze() |> Analysis.with_line_index()
    {:ok, format_lint_report(analysis, lint_findings(analysis, lint_backends(args)))}
  end

  defp call_tool("lint_problem", _args) do
    {:error, "Error: lint_problem requires 'problem'"}
  end

  defp call_tool(name, _args), do: {:error, "Unknown tool: #{name}"}

  # --- Backend resolution and option forwarding ---

  defp resolve_backend(name) when is_binary(name) do
    case Map.fetch(backends(), name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        known = backends() |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        {:error, "unknown backend #{inspect(name)}; known: " <> known}
    end
  end

  defp resolve_backend(_), do: {:error, "backend must be a string"}

  # Strip MCP-protocol keys before forwarding the remainder as a keyword list
  # of per-call backend overrides. Each backend validates its options and
  # raises on unknown keys, so only the ones it understands are forwarded.
  # `raw` is not among them: it selects how AtpMcp renders the result.
  defp opts_from(args, "sotptp"), do: opts_from_filtered(args, [:time_limit_sec, :url])

  defp opts_from(args, "isabelle") do
    filtered = opts_from_filtered(args, [:use_theories_timeout_ms])
    rename_key(filtered, :timeout_ms, :use_theories_timeout_ms, args)
  end

  defp opts_from(args, "local_exec"),
    do: opts_from_filtered(args, [:binary, :args, :cpu_timeout_s, :wall_timeout_ms])

  defp opts_from(args, "starexec"),
    do:
      opts_from_filtered(args, [
        :base_url,
        :username,
        :password,
        :request_timeout_ms,
        :poll_interval_ms,
        :timeout_ms
      ])

  defp opts_from(args, _), do: opts_from_filtered(args, [:time_limit_sec])

  defp opts_from_filtered(args, allowed) do
    args
    |> Map.drop(@protocol_keys)
    |> Enum.reduce([], fn {key, value}, acc ->
      atom = safe_to_atom(key)
      if atom in allowed, do: [{atom, value} | acc], else: acc
    end)
  end

  defp rename_key(opts, from, to, args) do
    case Map.fetch(args, Atom.to_string(from)) do
      {:ok, value} -> Keyword.put(opts, to, value)
      :error -> opts
    end
  end

  defp safe_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp time_limit_opt(%{"time_limit_sec" => t}) when is_integer(t), do: [time_limit_sec: t]
  defp time_limit_opt(_), do: []

  @lint_backends [:local, :tptp4x]

  defp lint_backends(%{"backends" => names}) when is_list(names) do
    case Enum.flat_map(names, &parse_lint_backend/1) do
      [] -> @lint_backends
      backends -> backends
    end
  end

  defp lint_backends(_), do: @lint_backends

  defp parse_lint_backend("local"), do: [:local]
  defp parse_lint_backend("tptp4x"), do: [:tptp4x]
  defp parse_lint_backend(_), do: []

  # --- Lint passes ---

  # Each pass yields rendered report lines, so a pass that did not run can
  # say so instead of passing for a clean bill of health.
  defp lint_findings(analysis, backends), do: Enum.flat_map(backends, &lint_pass(&1, analysis))

  defp lint_pass(:local, analysis), do: format_diagnostics(analysis, "tptp", analysis.diagnostics)

  # TPTP4X's view of a file that does not parse only adds noise on top of the
  # local error that has to be fixed first.
  defp lint_pass(:tptp4x, analysis) do
    if Diagnostic.any_errors?(analysis.diagnostics) do
      ["tptp4x skipped: the local pass found errors"]
    else
      analysis
      |> Tptp.Analyzer.run_all([tptp4x()])
      |> Enum.flat_map(fn {id, outcome} -> format_outcome(analysis, id, outcome) end)
    end
  end

  defp format_outcome(_analysis, _id, :skipped), do: []

  defp format_outcome(analysis, id, diagnostics),
    do: format_diagnostics(analysis, Atom.to_string(id), diagnostics)

  # --- Result formatting ---

  defp render({:ok, %Result{} = result}, args),
    do: {:ok, format_result(result, Map.get(args, "raw", false))}

  defp render({:error, {:unknown_system, name} = reason}, _args),
    do: {:error, "Error: #{name} is #{describe_failure(reason)}"}

  defp render({:error, reason}, _args), do: {:error, "Error: #{describe_failure(reason)}"}

  # AtpClient answers one entry per requested system, in the order requested,
  # but keys a result by the identifier that ran ("Vampire---5.0.1") and a
  # failure by the name given. Each row is labelled with what the caller
  # asked for, so "Vampire" finds its row, and names the version that ran
  # when the request was a bare name.
  defp format_compare_report(results, requested) do
    requested
    |> Enum.zip(results)
    |> Enum.map_join("\n", &format_compare_row/1)
  end

  defp format_compare_row({requested, {ran, {:ok, result}}}),
    do: "#{compare_label(requested, ran)}: #{format_result(result, false)}"

  defp format_compare_row({requested, {_key, {:error, reason}}}),
    do: "#{requested}: #{describe_failure(reason)}"

  defp compare_label(requested, requested), do: requested
  defp compare_label(requested, ran), do: "#{requested} (#{ran})"

  # The failures a caller can act on, in words; anything else as AtpClient
  # reported it.
  defp describe_failure({:unknown_system, _name}),
    do: "not a system on SystemOnTPTP (see list_provers)"

  defp describe_failure(:no_output), do: "SystemOnTPTP returned no output for this system"
  defp describe_failure(reason), do: inspect(reason)

  # A result's status is always a `Tptp.Szs.Ontology` value — AtpClient
  # reports a status word outside the ontology as an error — so its
  # canonical SZS name (`Theorem`, `CounterSatisfiable`, …) is the verdict.
  # `raw` asks for what the system printed instead.
  defp format_result(%Result{output: output}, true), do: output
  defp format_result(%Result{status: status}, _raw), do: Ontology.name(status)

  defp format_lint_report(analysis, lines) do
    [diagnostics_section(lines), symbols_section(declared_symbols(analysis), analysis)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp diagnostics_section([]), do: "OK (no diagnostics)"
  defp diagnostics_section(lines), do: Enum.join(lines, "\n")

  defp symbols_section([], _analysis), do: ""

  defp symbols_section(symbols, analysis) do
    "Symbols:\n" <> Enum.map_join(symbols, "\n", &format_symbol(&1, analysis))
  end

  # Only declared symbols carry a type worth reporting; FOF and CNF symbols
  # are used without declaration and would only restate the input.
  defp declared_symbols(analysis) do
    analysis.table.symbols
    |> Map.values()
    |> Enum.filter(&(&1.declared_as && &1.declared_at))
    |> Enum.sort_by(& &1.declared_at.offset)
  end

  defp format_diagnostics(analysis, source, diagnostics),
    do: Enum.map(diagnostics, &format_diagnostic(&1, source, analysis))

  defp format_diagnostic(%Diagnostic{} = diagnostic, source, analysis) do
    {line, column} = Analysis.line_column(analysis, diagnostic.span.offset)

    "#{line}:#{column} [#{diagnostic.severity}] (#{source}) " <>
      "#{diagnostic.message} [#{diagnostic.code}]" <> format_hint(diagnostic.hint)
  end

  defp format_hint(nil), do: ""
  defp format_hint(hint), do: "\n    hint: #{hint}"

  defp format_symbol(symbol, analysis) do
    {line, column} = Analysis.line_column(analysis, symbol.declared_at.offset)
    type = Tptp.Printer.Canonical.to_string(symbol.declared_as)
    "  #{symbol.name} : #{type} (declared at #{line}:#{column})"
  end

  # --- SZS ontology reference ---

  # Generated once at compile time from `Tptp.Szs.Ontology`, the same table
  # AtpClient reads verdicts against, so the reference cannot drift from the
  # statuses the tools report. Kept in the escript so an agent with only
  # stdio access can look up what "CounterSatisfiable" or "ResourceOut" means
  # without a round-trip to tptp.org. The Data ontology is left out: it names
  # output blocks, not verdicts.
  szs_entries = fn ontology ->
    for value <- Ontology.values(), Ontology.ontology(value) == ontology, into: "" do
      "  #{Ontology.name(value)} (#{Ontology.mnemonic(value)})\n" <>
        "      #{Ontology.describe(value)}\n"
    end
  end

  @szs_ontology_text """
  SZS Ontology — TPTP status verdicts
  ===================================

  Every backend result reports one status from Geoff Sutcliffe's SZS
  Ontology (#{Tptp.Szs.Page.source()}). Statuses split into Success (the
  prover established something about the input) and NoSuccess (it did not).
  Within Success, verdicts differ in what was established — a Theorem (the
  conjecture follows from the axioms) is not the same as Unsatisfiable (the
  clause set has no model), even though a refutational prover reaches both
  through the same saturation. Below, Ax are the axioms and C the conjecture.

  Success
  -------

  #{szs_entries.(:success)}
  NoSuccess
  ---------

  #{szs_entries.(:no_success)}\
  """

  defp szs_ontology_text, do: @szs_ontology_text

  # --- MCP tool schemas ---

  @raw_description "Return the system's verbatim output instead of the SZS verdict"

  @system_id_description "Prover ID from list_provers (\"Vampire---5.0.1\"), or a bare " <>
                           "system name (\"Vampire\") for the latest version offered"

  defp tool_schemas do
    [
      %{
        name: "list_backends",
        description:
          "List the AtpClient backends this MCP server exposes (sotptp, isabelle, local_exec, starexec) and their human-readable labels.",
        inputSchema: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "describe_szs",
        description: """
        Return a text description of the SZS Ontology
        (https://tptp.org/UserDocs/SZSOntology/), the vocabulary every other
        tool uses to report verdicts. Enumerates each Success status
        (Theorem, Unsatisfiable, Satisfiable, CounterSatisfiable, …) and
        NoSuccess status (GaveUp, Timeout, ResourceOut, Forced, …) with a
        short gloss so an agent can decide what a verdict means without
        leaving the MCP session.
        """,
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
        normalised SZS Ontology verdict (Theorem, Unsatisfiable, Satisfiable,
        CounterSatisfiable, GaveUp, Timeout, ResourceOut, …). The unified
        `AtpClient.Backend.query/2` entry point — each backend hides its
        ceremony (session, prover selection, theory bookkeeping) behind this
        call. Call `describe_szs` for the full ontology.
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
            raw: %{type: "boolean", description: @raw_description}
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
        Returns the SZS Ontology verdict (Theorem, Unsatisfiable, Satisfiable,
        CounterSatisfiable, GaveUp, Timeout, ResourceOut, …) or raw output.
        Call `describe_szs` for the full ontology.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            problem: %{type: "string", description: "TPTP problem text"},
            system_id: %{type: "string", description: @system_id_description},
            time_limit_sec: %{type: "integer", description: "Time limit in seconds"},
            raw: %{type: "boolean", description: @raw_description}
          },
          required: ["problem", "system_id"]
        }
      },
      %{
        name: "compare_provers",
        description: """
        Submit a TPTP problem to multiple SystemOnTPTP provers simultaneously
        and report SZS Ontology verdicts side-by-side. Useful for
        cross-checking or finding the fastest prover for a problem class.
        Call `describe_szs` for the vocabulary used in the output.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            problem: %{type: "string", description: "TPTP problem text"},
            system_ids: %{
              type: "array",
              items: %{type: "string"},
              description: "Prover IDs or bare system names to compare"
            },
            time_limit_sec: %{type: "integer", description: "Time limit per prover in seconds"}
          },
          required: ["problem", "system_ids"]
        }
      },
      %{
        name: "prove_isabelle",
        description: """
        Submit a hand-written Isabelle/HOL theory to the Isabelle server
        configured for this MCP server. The theory text is written into the
        configured shared directory and processed via `use_theories` on the
        long-lived session held by `AtpMcp.IsabelleSession` (session name,
        host, port, and credentials all come from application config — they
        are fixed for the lifetime of the server and cannot be overridden
        per call). For TPTP/THF problems use `query_backend` with
        `backend: "isabelle"` instead — that routes through `prove_tptp` on
        the same shared session.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            theory: %{type: "string", description: "Isabelle theory text"},
            theory_name: %{
              type: "string",
              description: "Theory name (also used as the .thy filename)"
            },
            timeout_ms: %{
              type: "integer",
              description: "Overall use_theories timeout in milliseconds"
            },
            raw: %{type: "boolean", description: @raw_description}
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
