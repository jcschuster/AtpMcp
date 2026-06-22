defmodule AtpMcpTest do
  use ExUnit.Case, async: true
  import Mox

  alias AtpClient.Lint.{Diagnostic, Report, Symbol}

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
      expect(AtpMcp.MockSotptp, :list_provers, fn -> [] end)
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
        {:ok, :thm}
      end)

      result =
        tool_call(95, "query_backend", %{"backend" => "local_exec", "problem" => @problem})

      assert text_of(result) == "Theorem"
    end

    test "forwards backend-appropriate options (sotptp time_limit_sec)" do
      expect(AtpMcp.MockSotptp, :query, fn _problem, opts ->
        assert opts[:time_limit_sec] == 15
        {:ok, :thm}
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
        {:ok, :thm}
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
      expect(AtpMcp.MockSotptp, :list_provers, fn ->
        ["Vampire---4.5", "E---2.0", "Z3---4.12"]
      end)

      result = tool_call(10, "list_provers", %{})
      assert text_of(result) == "E---2.0\nVampire---4.5\nZ3---4.12"
    end

    test "returns empty string when no provers are available" do
      expect(AtpMcp.MockSotptp, :list_provers, fn -> [] end)
      result = tool_call(11, "list_provers", %{})
      assert text_of(result) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # run_prover
  # ---------------------------------------------------------------------------

  describe "run_prover — result formatting" do
    for {atom, label} <- [
          thm: "Theorem",
          csat: "Countersatisfiable",
          sat: "Satisfiable",
          timeout: "Timeout",
          out_of_resources: "Out of resources",
          gave_up: "Gave up",
          interrupted: "Interrupted"
        ] do
      test "#{inspect(atom)} formats as #{inspect(label)}" do
        atom = unquote(atom)
        label = unquote(label)
        expect(AtpMcp.MockSotptp, :query_system, fn _, _, _ -> {:ok, atom} end)

        result = tool_call(20, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
        assert text_of(result) == label
      end
    end

    test "raw string passthrough (raw: true)" do
      raw_output = "% SZS status Theorem\n% CPU 0.01s"
      expect(AtpMcp.MockSotptp, :query_system, fn _, _, _ -> {:ok, raw_output} end)

      result =
        tool_call(27, "run_prover", %{
          "problem" => @problem,
          "system_id" => "E---2.0",
          "raw" => true
        })

      assert text_of(result) == raw_output
    end

    test "unrecognized atom falls back to inspect" do
      expect(AtpMcp.MockSotptp, :query_system, fn _, _, _ -> {:ok, :unknown_atom} end)
      result = tool_call(28, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert text_of(result) == ":unknown_atom"
    end
  end

  describe "run_prover — option forwarding" do
    test "passes time_limit_sec through to query_system" do
      expect(AtpMcp.MockSotptp, :query_system, fn _, _, opts ->
        assert opts[:time_limit_sec] == 30
        {:ok, :thm}
      end)

      tool_call(30, "run_prover", %{
        "problem" => @problem,
        "system_id" => "E---2.0",
        "time_limit_sec" => 30
      })
    end

    test "passes raw: true through to query_system" do
      expect(AtpMcp.MockSotptp, :query_system, fn _, _, opts ->
        assert opts[:raw] == true
        {:ok, "raw output"}
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
        {:ok, :thm}
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
           {"E---2.0", {:ok, :thm}},
           {"Vampire---4.5", {:ok, :timeout}}
         ]}
      end)

      result =
        tool_call(50, "compare_provers", %{
          "problem" => @problem,
          "system_ids" => ["E---2.0", "Vampire---4.5"]
        })

      assert text_of(result) == "E---2.0: Theorem\nVampire---4.5: Timeout"
    end

    test "formats an error result from one prover" do
      expect(AtpMcp.MockSotptp, :query_selected_systems, fn _, _, _ ->
        {:ok,
         [
           {"E---2.0", {:ok, :thm}},
           {"Broken---1.0", {:error, :malformed_input}}
         ]}
      end)

      result =
        tool_call(51, "compare_provers", %{
          "problem" => @problem,
          "system_ids" => ["E---2.0", "Broken---1.0"]
        })

      text = text_of(result)
      assert String.contains?(text, "E---2.0: Theorem")
      assert String.contains?(text, "Broken---1.0: error(")
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
      expect(AtpMcp.MockIsabelle, :query, fn _theory, _name, _opts -> {:ok, :thm} end)

      result =
        tool_call(70, "prove_isabelle", %{"theory" => @theory, "theory_name" => "Example"})

      assert text_of(result) == "Theorem"
    end

    test "forwards session/host/port/timeout/raw options" do
      expect(AtpMcp.MockIsabelle, :query, fn theory, name, opts ->
        assert theory == @theory
        assert name == "Example"
        assert opts[:session] == "Main"
        assert opts[:host] == "isabelle.example.org"
        assert opts[:port] == 9999
        assert opts[:use_theories_timeout_ms] == 30_000
        assert opts[:raw] == true
        {:ok, %{"ok" => true, "errors" => [], "nodes" => []}}
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
      expect(AtpMcp.MockIsabelle, :query, fn _, _, _ ->
        {:error, {:connect_failed, :econnrefused}}
      end)

      result =
        tool_call(72, "prove_isabelle", %{"theory" => @theory, "theory_name" => "Example"})

      assert String.starts_with?(text_of(result), "Error:")
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
    test "reports a clean problem as OK" do
      expect(AtpMcp.MockLint, :analyze, fn _, _ ->
        %Report{diagnostics: [], symbols: []}
      end)

      result = tool_call(80, "lint_problem", %{"problem" => "fof(a, axiom, p)."})
      assert text_of(result) == "OK (no diagnostics)"
    end

    test "formats diagnostics with severity, source, and position" do
      expect(AtpMcp.MockLint, :analyze, fn _, _ ->
        %Report{
          diagnostics: [
            %Diagnostic{
              line: 1,
              column: 7,
              severity: :error,
              message: "unknown TPTP role `axim`",
              source: "local"
            },
            %Diagnostic{
              line: 3,
              column: 1,
              severity: :warning,
              message: "missing terminator",
              source: "tptp4x"
            }
          ],
          symbols: []
        }
      end)

      result = tool_call(81, "lint_problem", %{"problem" => "fof(a, axim, p)."})
      text = text_of(result)
      assert text =~ "1:7 [error] (local) unknown TPTP role `axim`"
      assert text =~ "3:1 [warning] (tptp4x) missing terminator"
    end

    test "appends symbols when present" do
      expect(AtpMcp.MockLint, :analyze, fn _, _ ->
        %Report{
          diagnostics: [],
          symbols: [%Symbol{name: "plus", kind: :type_decl, type: "$i > $i", line: 2, column: 5}]
        }
      end)

      result = tool_call(82, "lint_problem", %{"problem" => "tff(a, type, plus: $i > $i)."})
      text = text_of(result)
      assert text =~ "Symbols:"
      assert text =~ "plus : $i > $i (type_decl at 2:5)"
    end

    test "forwards a parsed backends list" do
      expect(AtpMcp.MockLint, :analyze, fn _, opts ->
        assert opts[:backends] == [:local]
        %Report{diagnostics: [], symbols: []}
      end)

      tool_call(83, "lint_problem", %{
        "problem" => "fof(a, axiom, p).",
        "backends" => ["local"]
      })
    end

    test "ignores unknown backend names" do
      expect(AtpMcp.MockLint, :analyze, fn _, opts ->
        refute Keyword.has_key?(opts, :backends)
        %Report{diagnostics: [], symbols: []}
      end)

      tool_call(84, "lint_problem", %{
        "problem" => "fof(a, axiom, p).",
        "backends" => ["nonsense"]
      })
    end

    test "missing problem returns a descriptive error" do
      result = tool_call(85, "lint_problem", %{})
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
