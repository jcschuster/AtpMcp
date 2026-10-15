defmodule AtpMcpTest do
  use ExUnit.Case, async: true
  import Mox

  import AtpMcp.TestSupport

  @problem "fof(ax,axiom,p). fof(conj,conjecture,p)."

  setup :verify_on_exit!

  defp rpc(msg) do
    line = Jason.encode!(msg)

    case AtpMcp.handle_rpc(line) do
      nil -> :silent
      json -> {:ok, Jason.decode!(json)}
    end
  end

  defp tool_call(id, name, args) do
    rpc(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    })
  end

  defp tool_call_no_args(id, name) do
    rpc(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name}
    })
  end

  defp text_of({:ok, %{"result" => %{"content" => [%{"text" => t}]}}}), do: t

  # ---------------------------------------------------------------------------
  # Protocol layer — no backend calls
  # ---------------------------------------------------------------------------

  describe "blank / malformed input" do
    test "empty string returns nil (no response)" do
      assert AtpMcp.handle_rpc("") == nil
    end

    test "whitespace-only line returns nil" do
      assert AtpMcp.handle_rpc("   \t\n") == nil
    end

    test "malformed JSON returns a -32700 parse error" do
      {:ok, resp} = rpc_raw("{not valid json}")
      assert resp["error"]["code"] == -32_700
      assert resp["error"]["message"] == "Parse error"
      assert resp["id"] == nil
    end
  end

  describe "initialize" do
    test "advertises MCP revision 2025-11-25 and server info" do
      {:ok, resp} =
        rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})

      assert resp["id"] == 1
      assert resp["result"]["protocolVersion"] == "2025-11-25"
      assert resp["result"]["serverInfo"]["name"] == "atp"
      assert is_binary(resp["result"]["serverInfo"]["version"])
      assert get_in(resp, ["result", "capabilities", "tools"]) == %{}
    end
  end

  describe "ping" do
    test "returns empty result" do
      {:ok, resp} = rpc(%{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})
      assert resp["id"] == 2
      assert resp["result"] == %{}
    end
  end

  describe "tools/list" do
    test "advertises every declared tool" do
      {:ok, resp} = rpc(%{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"})
      tools = resp["result"]["tools"]
      names = tools |> Enum.map(& &1["name"]) |> Enum.sort()

      assert names == [
               "compare_provers",
               "describe_szs",
               "lint_problem",
               "list_backends",
               "list_provers",
               "prove_isabelle",
               "query_backend",
               "run_prover",
               "verify_backend"
             ]
    end

    test "each tool has an inputSchema" do
      {:ok, resp} = rpc(%{"jsonrpc" => "2.0", "id" => 4, "method" => "tools/list"})
      tools = resp["result"]["tools"]
      Enum.each(tools, fn t -> assert is_map(t["inputSchema"]) end)
    end
  end

  describe "notifications" do
    test "notifications/initialized produces no response" do
      assert :silent == rpc(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    end

    test "initialized produces no response" do
      assert :silent == rpc(%{"jsonrpc" => "2.0", "method" => "initialized"})
    end

    test "unknown notification without id produces no response" do
      assert :silent == rpc(%{"jsonrpc" => "2.0", "method" => "notifications/foo"})
    end
  end

  describe "unknown method" do
    test "returns -32601 method-not-found error" do
      {:ok, resp} = rpc(%{"jsonrpc" => "2.0", "id" => 5, "method" => "no_such_method"})
      assert resp["id"] == 5
      assert resp["error"]["code"] == -32_601
    end
  end

  describe "tools/call — protocol edge cases" do
    test "missing 'arguments' key defaults to empty map" do
      expect(AtpMcp.MockSotptp, :systems, fn [capability: :prove] -> [] end)
      result = tool_call_no_args(6, "list_provers")
      assert text_of(result) == ""
    end

    test "missing 'name' key returns an error in the tool result" do
      {:ok, resp} =
        rpc(%{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/call",
          "params" => %{"arguments" => %{}}
        })

      assert String.starts_with?(text_of({:ok, resp}), "Error:")
    end

    test "unknown tool name returns descriptive message" do
      result = tool_call(8, "nonexistent_tool", %{})
      assert text_of(result) == "Unknown tool: nonexistent_tool"
    end
  end

  # ---------------------------------------------------------------------------
  # list_backends / verify_backend / query_backend (unified contract)
  # ---------------------------------------------------------------------------

  describe "describe_szs" do
    test "returns a reference for both Success and NoSuccess statuses" do
      result = tool_call(89, "describe_szs", %{})
      text = text_of(result)
      # Success entries
      assert text =~ "Theorem"
      assert text =~ "Unsatisfiable"
      assert text =~ "CounterSatisfiable"
      assert text =~ "ContradictoryAxioms"
      # NoSuccess entries
      assert text =~ "GaveUp"
      assert text =~ "Timeout"
      assert text =~ "ResourceOut"
      assert text =~ "Forced"
      # Source reference
      assert text =~ "tptp.org"
    end

    test "ignores unknown arguments" do
      result = tool_call(88, "describe_szs", %{"anything" => "here"})
      assert text_of(result) =~ "SZS Ontology"
    end
  end

  describe "list_backends" do
    test "returns the registered backends and their labels, alphabetically" do
      expect(AtpMcp.MockSotptp, :label, fn -> "SystemOnTPTP" end)
      expect(AtpMcp.MockIsabelle, :label, fn -> "Isabelle" end)
      expect(AtpMcp.MockLocalExec, :label, fn -> "Local prover" end)
      expect(AtpMcp.MockStarExec, :label, fn -> "StarExec" end)

      result = tool_call(90, "list_backends", %{})

      assert text_of(result) ==
               """
               isabelle\tIsabelle
               local_exec\tLocal prover
               sotptp\tSystemOnTPTP
               starexec\tStarExec\
               """
    end
  end

  describe "verify_backend" do
    test "returns OK when the backend says :ok" do
      expect(AtpMcp.MockLocalExec, :verify, fn _opts -> :ok end)
      result = tool_call(91, "verify_backend", %{"backend" => "local_exec"})
      assert text_of(result) == "OK"
    end

    test "returns a descriptive error when the backend fails" do
      expect(AtpMcp.MockStarExec, :verify, fn _opts -> {:error, :no_route_to_host} end)
      result = tool_call(92, "verify_backend", %{"backend" => "starexec"})
      assert text_of(result) =~ "Error:"
      assert text_of(result) =~ "no_route_to_host"
    end

    test "unknown backend name yields a descriptive error listing known ones" do
      result = tool_call(93, "verify_backend", %{"backend" => "nope"})
      text = text_of(result)
      assert text =~ "unknown backend"
      assert text =~ "sotptp"
      assert text =~ "isabelle"
    end

    test "missing backend key returns a descriptive error" do
      result = tool_call(94, "verify_backend", %{})
      assert String.contains?(text_of(result), "Error:")
    end
  end

  describe "query_backend" do
    test "dispatches to the named backend's query/2" do
      expect(AtpMcp.MockLocalExec, :query, fn problem, _opts ->
        assert problem == @problem
        {:ok, result(:theorem)}
      end)

      result =
        tool_call(95, "query_backend", %{"backend" => "local_exec", "problem" => @problem})

      assert text_of(result) == "Theorem"
    end

    test "forwards backend-appropriate options (sotptp time_limit_sec)" do
      expect(AtpMcp.MockSotptp, :query, fn _problem, opts ->
        assert opts[:time_limit_sec] == 15
        {:ok, result(:theorem)}
      end)

      tool_call(96, "query_backend", %{
        "backend" => "sotptp",
        "problem" => @problem,
        "time_limit_sec" => 15
      })
    end

    test "renames timeout_ms → use_theories_timeout_ms for isabelle" do
      expect(AtpMcp.MockIsabelle, :query, fn _problem, opts ->
        assert opts[:use_theories_timeout_ms] == 20_000
        {:ok, result(:theorem)}
      end)

      tool_call(97, "query_backend", %{
        "backend" => "isabelle",
        "problem" => @problem,
        "timeout_ms" => 20_000
      })
    end

    test "surfaces backend errors" do
      expect(AtpMcp.MockLocalExec, :query, fn _, _ ->
        {:error, {:prover_not_found, "eprover"}}
      end)

      result =
        tool_call(98, "query_backend", %{"backend" => "local_exec", "problem" => @problem})

      assert String.starts_with?(text_of(result), "Error:")
      assert text_of(result) =~ "prover_not_found"
    end

    test "unknown backend yields a descriptive error" do
      result = tool_call(99, "query_backend", %{"backend" => "bogus", "problem" => @problem})
      assert text_of(result) =~ "unknown backend"
    end

    test "missing required args returns a descriptive error" do
      result = tool_call(100, "query_backend", %{"backend" => "sotptp"})
      assert String.contains?(text_of(result), "Error:")
    end
  end

  # ---------------------------------------------------------------------------
  # list_provers
  # ---------------------------------------------------------------------------

  describe "list_provers" do
    test "returns provers sorted alphabetically, one per line" do
      expect(AtpMcp.MockSotptp, :systems, fn [capability: :prove] ->
        Enum.map(["Vampire---4.5", "E---2.0", "Z3---4.12"], &%AtpClient.System{id: &1})
      end)

      result = tool_call(10, "list_provers", %{})
      assert text_of(result) == "E---2.0\nVampire---4.5\nZ3---4.12"
    end

    test "returns empty string when no provers are available" do
      expect(AtpMcp.MockSotptp, :systems, fn [capability: :prove] -> [] end)
      result = tool_call(11, "list_provers", %{})
      assert text_of(result) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # run_prover
  # ---------------------------------------------------------------------------

  describe "run_prover — result formatting" do
    # A result's status is a `Tptp.Szs.Ontology` value; AtpMcp renders its
    # canonical SZS name. Covers a representative slice of both Success and
    # NoSuccess, including names that are not a plain camelization.
    for {atom, label} <- [
          theorem: "Theorem",
          unsatisfiable: "Unsatisfiable",
          satisfiable: "Satisfiable",
          counter_satisfiable: "CounterSatisfiable",
          contradictory_axioms: "ContradictoryAxioms",
          equivalent: "Equivalent",
          tautology: "Tautology",
          gave_up: "GaveUp",
          unknown: "Unknown",
          timeout: "Timeout",
          resource_out: "ResourceOut",
          memory_out: "MemoryOut",
          forced: "Forced",
          inappropriate: "Inappropriate",
          input_error: "InputError",
          equivalent_theorem: "EquivalentTheorem",
          os_error: "OSError",
          cpu_timeout: "CPUTimeout",
          wc_timeout: "WCTimeout"
        ] do
      test "#{inspect(atom)} formats as #{inspect(label)}" do
        atom = unquote(atom)
        label = unquote(label)
        expect(AtpMcp.MockSotptp, :query_system, fn _, _, _ -> {:ok, result(atom)} end)

        result = tool_call(20, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
        assert text_of(result) == label
      end
    end

    test "raw: true returns the system's verbatim output" do
      raw_output = "% SZS status Theorem\n% CPU 0.01s"

      expect(AtpMcp.MockSotptp, :query_system, fn _, _, _ ->
        {:ok, result(:theorem, raw_output)}
      end)

      result =
        tool_call(27, "run_prover", %{
          "problem" => @problem,
          "system_id" => "E---2.0",
          "raw" => true
        })

      assert text_of(result) == raw_output
    end
  end

  describe "run_prover — option forwarding" do
    test "passes time_limit_sec through to query_system" do
      expect(AtpMcp.MockSotptp, :query_system, fn _, _, opts ->
        assert opts[:time_limit_sec] == 30
        {:ok, result(:theorem)}
      end)

      tool_call(30, "run_prover", %{
        "problem" => @problem,
        "system_id" => "E---2.0",
        "time_limit_sec" => 30
      })
    end

    test "does not forward raw (AtpClient rejects unknown options)" do
      expect(AtpMcp.MockSotptp, :query_system, fn _, _, opts ->
        refute Keyword.has_key?(opts, :raw)
        {:ok, result(:theorem, "raw output")}
      end)

      tool_call(31, "run_prover", %{
        "problem" => @problem,
        "system_id" => "E---2.0",
        "raw" => true
      })
    end

    test "omits time_limit_sec when not provided" do
      expect(AtpMcp.MockSotptp, :query_system, fn _, _, opts ->
        refute Keyword.has_key?(opts, :time_limit_sec)
        {:ok, result(:theorem)}
      end)

      tool_call(32, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
    end
  end

  describe "run_prover — error handling" do
    test "HTTP error surfaces as 'Error: …' in the tool result" do
      expect(AtpMcp.MockSotptp, :query_system, fn _, _, _ ->
        {:error, %{reason: :timeout}}
      end)

      result = tool_call(40, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert String.starts_with?(text_of(result), "Error:")
    end

    test "an unknown system is described in words" do
      expect(AtpMcp.MockSotptp, :query_system, fn _, _, _ ->
        {:error, {:unknown_system, "Nope"}}
      end)

      result = tool_call(44, "run_prover", %{"problem" => @problem, "system_id" => "Nope"})

      assert text_of(result) ==
               "Error: Nope is not a system on SystemOnTPTP (see list_provers)"
    end

    test "missing system_id returns a descriptive error" do
      result = tool_call(41, "run_prover", %{"problem" => @problem})
      text = text_of(result)
      assert String.contains?(text, "Error:")
      refute text == "Unknown tool: run_prover"
    end

    test "missing problem returns a descriptive error" do
      result = tool_call(42, "run_prover", %{"system_id" => "E---2.0"})
      text = text_of(result)
      assert String.contains?(text, "Error:")
      refute text == "Unknown tool: run_prover"
    end

    test "completely empty args returns a descriptive error" do
      result = tool_call(43, "run_prover", %{})
      text = text_of(result)
      assert String.contains?(text, "Error:")
      refute text == "Unknown tool: run_prover"
    end
  end

  # ---------------------------------------------------------------------------
  # compare_provers
  # ---------------------------------------------------------------------------

  describe "compare_provers — result formatting" do
    test "formats multiple prover results on separate lines" do
      expect(AtpMcp.MockSotptp, :query_selected_systems, fn _, _, _ ->
        {:ok,
         [
           {"E---2.0", {:ok, result(:theorem)}},
           {"Vampire---4.5", {:ok, result(:counter_satisfiable)}},
           {"Z3---4.12", {:ok, result(:timeout)}}
         ]}
      end)

      result =
        tool_call(50, "compare_provers", %{
          "problem" => @problem,
          "system_ids" => ["E---2.0", "Vampire---4.5", "Z3---4.12"]
        })

      assert text_of(result) ==
               "E---2.0: Theorem\nVampire---4.5: CounterSatisfiable\nZ3---4.12: Timeout"
    end

    test "labels each row with the name requested, and the version a bare name ran" do
      expect(AtpMcp.MockSotptp, :query_selected_systems, fn _, ["Vampire", "E---3.5.1"], _ ->
        {:ok,
         [
           {"Vampire---5.0.1", {:ok, result(:counter_satisfiable)}},
           {"E---3.5.1", {:ok, result(:counter_satisfiable)}}
         ]}
      end)

      result =
        tool_call(51, "compare_provers", %{
          "problem" => @problem,
          "system_ids" => ["Vampire", "E---3.5.1"]
        })

      assert text_of(result) ==
               "Vampire (Vampire---5.0.1): CounterSatisfiable\nE---3.5.1: CounterSatisfiable"
    end

    test "describes per-system failures in words" do
      expect(AtpMcp.MockSotptp, :query_selected_systems, fn _, _, _ ->
        {:ok,
         [
           {"E---2.0", {:ok, result(:theorem)}},
           {"Nope", {:error, {:unknown_system, "Nope"}}},
           {"Quiet---1.0", {:error, :no_output}},
           {"Broken---1.0", {:error, :malformed_input}}
         ]}
      end)

      result =
        tool_call(55, "compare_provers", %{
          "problem" => @problem,
          "system_ids" => ["E---2.0", "Nope", "Quiet---1.0", "Broken---1.0"]
        })

      assert text_of(result) ==
               """
               E---2.0: Theorem
               Nope: not a system on SystemOnTPTP (see list_provers)
               Quiet---1.0: SystemOnTPTP returned no output for this system
               Broken---1.0: :malformed_input\
               """
    end

    test "empty result list produces empty string" do
      expect(AtpMcp.MockSotptp, :query_selected_systems, fn _, _, _ -> {:ok, []} end)

      result =
        tool_call(52, "compare_provers", %{
          "problem" => @problem,
          "system_ids" => []
        })

      assert text_of(result) == ""
    end
  end

  describe "compare_provers — option forwarding" do
    test "passes time_limit_sec to query_selected_systems" do
      expect(AtpMcp.MockSotptp, :query_selected_systems, fn _, _, opts ->
        assert opts[:time_limit_sec] == 60
        {:ok, []}
      end)

      tool_call(53, "compare_provers", %{
        "problem" => @problem,
        "system_ids" => ["E---2.0"],
        "time_limit_sec" => 60
      })
    end
  end

  describe "compare_provers — error handling" do
    test "HTTP error surfaces as 'Error: …' in the tool result" do
      expect(AtpMcp.MockSotptp, :query_selected_systems, fn _, _, _ ->
        {:error, "API Error: status 503"}
      end)

      result =
        tool_call(60, "compare_provers", %{
          "problem" => @problem,
          "system_ids" => ["E---2.0"]
        })

      assert String.starts_with?(text_of(result), "Error:")
    end

    test "missing system_ids returns a descriptive error" do
      result = tool_call(61, "compare_provers", %{"problem" => @problem})
      assert String.contains?(text_of(result), "Error:")
    end

    test "missing problem returns a descriptive error" do
      result = tool_call(62, "compare_provers", %{"system_ids" => ["E---2.0"]})
      assert String.contains?(text_of(result), "Error:")
    end
  end

  # ---------------------------------------------------------------------------
  # prove_isabelle
  # ---------------------------------------------------------------------------

  @theory ~S"""
  theory Example imports Main begin
  lemma "P \<or> \<not> P" by auto
  end
  """

  describe "prove_isabelle" do
    test "formats a normalized result" do
      expect(AtpMcp.MockIsabelle, :prove_theory, fn _theory, _name, _opts ->
        {:ok, result(:theorem)}
      end)

      result =
        tool_call(70, "prove_isabelle", %{"theory" => @theory, "theory_name" => "Example"})

      assert text_of(result) == "Theorem"
    end

    test "forwards timeout_ms (renamed); renders raw output; drops host/port/session" do
      expect(AtpMcp.MockIsabelle, :prove_theory, fn theory, name, opts ->
        assert theory == @theory
        assert name == "Example"
        assert opts[:use_theories_timeout_ms] == 30_000
        refute Keyword.has_key?(opts, :raw)
        # Per-call connection overrides are no longer forwarded — the
        # shared session is opened from application config only.
        refute Keyword.has_key?(opts, :session)
        refute Keyword.has_key?(opts, :host)
        refute Keyword.has_key?(opts, :port)
        {:ok, result(:theorem, "theory Example: ok, no errors")}
      end)

      result =
        tool_call(71, "prove_isabelle", %{
          "theory" => @theory,
          "theory_name" => "Example",
          "session" => "Main",
          "host" => "isabelle.example.org",
          "port" => 9999,
          "timeout_ms" => 30_000,
          "raw" => true
        })

      text = text_of(result)
      assert String.contains?(text, "ok")
      assert String.contains?(text, "errors")
    end

    test "surfaces backend errors" do
      expect(AtpMcp.MockIsabelle, :prove_theory, fn _, _, _ ->
        {:error, {:connect_failed, :econnrefused}}
      end)

      result =
        tool_call(72, "prove_isabelle", %{"theory" => @theory, "theory_name" => "Example"})

      assert String.starts_with?(text_of(result), "Error:")
      assert text_of(result) =~ "econnrefused"
    end

    test "missing required args returns a descriptive error" do
      result = tool_call(73, "prove_isabelle", %{"theory" => @theory})
      assert String.contains?(text_of(result), "Error:")
    end
  end

  # ---------------------------------------------------------------------------
  # lint_problem
  # ---------------------------------------------------------------------------

  describe "lint_problem" do
    # The local pass is the real `Tptp.analyze/2`; only the remote TPTP4X
    # analyzer is mocked. An unexpected `analyze/2` call would be caught by
    # `Tptp.Analyzer.run_all/3` and surface as a TPTP0800 finding, so the
    # default stub answers `[]` and the tests that care say so with `expect`.
    setup do
      stub(AtpMcp.MockTptp4x, :id, fn -> :tptp4x end)
      stub(AtpMcp.MockTptp4x, :dialects, fn -> :any end)
      stub(AtpMcp.MockTptp4x, :analyze, fn _, _ -> [] end)
      :ok
    end

    test "reports a clean problem as OK" do
      result = tool_call(80, "lint_problem", %{"problem" => "fof(a, axiom, p)."})
      assert text_of(result) == "OK (no diagnostics)"
    end

    test "formats local diagnostics with position, severity, source, code, and hint" do
      result = tool_call(81, "lint_problem", %{"problem" => "fof(a, axim, p)."})
      text = text_of(result)
      assert text =~ ~s|1:8 [warning] (tptp) "axim" is not a TPTP formula role [TPTP0401]|
      assert text =~ "    hint: expected one of axiom"
    end

    test "appends the remote analyzer's findings, tagged with its id" do
      expect(AtpMcp.MockTptp4x, :analyze, fn %Tptp.Analysis{}, _opts ->
        [Tptp.Diagnostic.new("TPTP4X", :warning, Tptp.Span.new(0, 18, 1), "missing terminator")]
      end)

      problem = "fof(a, axiom, p).\nfof(b, axiom, q)."
      result = tool_call(82, "lint_problem", %{"problem" => problem})
      assert text_of(result) =~ "2:1 [warning] (tptp4x) missing terminator [TPTP4X]"
    end

    test "skips the remote pass when the local pass found errors" do
      expect(AtpMcp.MockTptp4x, :analyze, 0, fn _, _ -> [] end)

      result = tool_call(83, "lint_problem", %{"problem" => "fof(a, axiom, p"})
      text = text_of(result)
      assert text =~ "[error] (tptp)"
      assert text =~ "tptp4x skipped"
    end

    test "appends declared symbols with their types" do
      result = tool_call(84, "lint_problem", %{"problem" => "tff(a, type, plus: $i > $i)."})
      text = text_of(result)
      assert text =~ "Symbols:"
      assert text =~ "plus : $i > $i (declared at 1:14)"
    end

    test "backends: [\"local\"] runs only the local pass" do
      expect(AtpMcp.MockTptp4x, :analyze, 0, fn _, _ -> [] end)

      result =
        tool_call(85, "lint_problem", %{
          "problem" => "fof(a, axiom, p).",
          "backends" => ["local"]
        })

      assert text_of(result) == "OK (no diagnostics)"
    end

    test "backends: [\"tptp4x\"] hides the local findings" do
      expect(AtpMcp.MockTptp4x, :analyze, fn _, _ -> [] end)

      result =
        tool_call(86, "lint_problem", %{
          "problem" => "fof(a, axim, p).",
          "backends" => ["tptp4x"]
        })

      assert text_of(result) == "OK (no diagnostics)"
    end

    test "unknown backend names fall back to both passes" do
      expect(AtpMcp.MockTptp4x, :analyze, fn _, _ -> [] end)

      tool_call(87, "lint_problem", %{
        "problem" => "fof(a, axiom, p).",
        "backends" => ["nonsense"]
      })
    end

    test "missing problem returns a descriptive error" do
      result = tool_call(88, "lint_problem", %{})
      assert String.contains?(text_of(result), "Error:")
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp rpc_raw(raw_string) do
    case AtpMcp.handle_rpc(raw_string) do
      nil -> :silent
      json -> {:ok, Jason.decode!(json)}
    end
  end
end
