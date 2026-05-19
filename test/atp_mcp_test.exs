defmodule AtpMcpTest do
  use ExUnit.Case, async: true
  import Mox

  # Each test that sets Mox expectations gets them verified on exit.
  setup :verify_on_exit!

  # Convenience: encode a map as a JSON-RPC line and pass it through handle_rpc,
  # then decode the response JSON. Returns {:ok, map} or :silent.
  defp rpc(msg) do
    line = Jason.encode!(msg)

    case AtpMcp.handle_rpc(line) do
      nil -> :silent
      json -> {:ok, Jason.decode!(json)}
    end
  end

  defp tool_call(id, name, args) do
    rpc(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call",
          "params" => %{"name" => name, "arguments" => args}})
  end

  defp tool_call_no_args(id, name) do
    rpc(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call",
          "params" => %{"name" => name}})
  end

  defp text_of({:ok, %{"result" => %{"content" => [%{"text" => t}]}}}), do: t

  # ---------------------------------------------------------------------------
  # Protocol layer — no AtpClient calls
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
    test "returns protocol version and server info" do
      {:ok, resp} = rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})
      assert resp["id"] == 1
      assert resp["result"]["protocolVersion"] == "2024-11-05"
      assert resp["result"]["serverInfo"]["name"] == "atp"
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
    test "returns exactly the three declared tools" do
      {:ok, resp} = rpc(%{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"})
      tools = resp["result"]["tools"]
      names = Enum.map(tools, & &1["name"]) |> Enum.sort()
      assert names == ["compare_provers", "list_provers", "run_prover"]
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
    test "missing 'arguments' key defaults to empty map (does not crash)" do
      # list_provers takes no arguments; a strict client may omit "arguments"
      expect(AtpMcp.MockAtp, :list_provers, fn -> [] end)
      result = tool_call_no_args(6, "list_provers")
      assert text_of(result) == ""
    end

    test "missing 'name' key returns an error in the tool result" do
      {:ok, resp} =
        rpc(%{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/call",
              "params" => %{"arguments" => %{}}})

      text = text_of({:ok, resp})
      assert String.starts_with?(text, "Error:")
    end

    test "unknown tool name returns descriptive message" do
      result = tool_call(8, "nonexistent_tool", %{})
      assert text_of(result) == "Unknown tool: nonexistent_tool"
    end
  end

  # ---------------------------------------------------------------------------
  # list_provers tool
  # ---------------------------------------------------------------------------

  describe "list_provers" do
    test "returns provers sorted alphabetically, one per line" do
      expect(AtpMcp.MockAtp, :list_provers, fn ->
        ["Vampire---4.5", "E---2.0", "Z3---4.12"]
      end)

      result = tool_call(10, "list_provers", %{})
      assert text_of(result) == "E---2.0\nVampire---4.5\nZ3---4.12"
    end

    test "returns empty string when no provers are available" do
      expect(AtpMcp.MockAtp, :list_provers, fn -> [] end)
      result = tool_call(11, "list_provers", %{})
      assert text_of(result) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # run_prover tool
  # ---------------------------------------------------------------------------

  @problem "fof(ax,axiom,p). fof(conj,conjecture,p)."

  describe "run_prover — result formatting" do
    test ":thm formats as 'Theorem'" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts -> {:ok, :thm} end)
      result = tool_call(20, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert text_of(result) == "Theorem"
    end

    test ":csat formats as 'Countersatisfiable'" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts -> {:ok, :csat} end)
      result = tool_call(21, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert text_of(result) == "Countersatisfiable"
    end

    test ":sat formats as 'Satisfiable'" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts -> {:ok, :sat} end)
      result = tool_call(22, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert text_of(result) == "Satisfiable"
    end

    test ":timeout formats as 'Timeout'" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts -> {:ok, :timeout} end)
      result = tool_call(23, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert text_of(result) == "Timeout"
    end

    test ":out_of_resources formats as 'Out of resources'" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts -> {:ok, :out_of_resources} end)
      result = tool_call(24, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert text_of(result) == "Out of resources"
    end

    test ":gave_up formats as 'Gave up'" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts -> {:ok, :gave_up} end)
      result = tool_call(25, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert text_of(result) == "Gave up"
    end

    test ":interrupted formats as 'Interrupted'" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts -> {:ok, :interrupted} end)
      result = tool_call(26, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert text_of(result) == "Interrupted"
    end

    test "raw string passthrough (raw: true)" do
      raw_output = "% SZS status Theorem\n% CPU 0.01s"
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts -> {:ok, raw_output} end)

      result =
        tool_call(27, "run_prover", %{
          "problem" => @problem,
          "system_id" => "E---2.0",
          "raw" => true
        })

      assert text_of(result) == raw_output
    end

    test "unrecognized atom falls back to inspect" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts -> {:ok, :unknown_atom} end)
      result = tool_call(28, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert text_of(result) == ":unknown_atom"
    end
  end

  describe "run_prover — option forwarding" do
    test "passes time_limit_sec through to query_system" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, opts ->
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
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, opts ->
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
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, opts ->
        refute Keyword.has_key?(opts, :time_limit_sec)
        {:ok, :thm}
      end)

      tool_call(32, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
    end
  end

  describe "run_prover — error handling" do
    test "HTTP error surfaces as 'Error: …' in the tool result" do
      expect(AtpMcp.MockAtp, :query_system, fn _prob, _sys, _opts ->
        {:error, %{reason: :timeout}}
      end)

      result = tool_call(40, "run_prover", %{"problem" => @problem, "system_id" => "E---2.0"})
      assert String.starts_with?(text_of(result), "Error:")
    end

    test "missing system_id returns a descriptive error, not 'Unknown tool'" do
      result = tool_call(41, "run_prover", %{"problem" => @problem})
      text = text_of(result)
      assert String.contains?(text, "Error:")
      refute text == "Unknown tool: run_prover"
    end

    test "missing problem returns a descriptive error, not 'Unknown tool'" do
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
  # compare_provers tool
  # ---------------------------------------------------------------------------

  describe "compare_provers — result formatting" do
    test "formats multiple prover results on separate lines" do
      expect(AtpMcp.MockAtp, :query_selected_systems, fn _prob, _ids, _opts ->
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

      text = text_of(result)
      assert text == "E---2.0: Theorem\nVampire---4.5: Timeout"
    end

    test "formats an error result from one prover" do
      expect(AtpMcp.MockAtp, :query_selected_systems, fn _prob, _ids, _opts ->
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
      expect(AtpMcp.MockAtp, :query_selected_systems, fn _prob, _ids, _opts -> {:ok, []} end)

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
      expect(AtpMcp.MockAtp, :query_selected_systems, fn _prob, _ids, opts ->
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
      expect(AtpMcp.MockAtp, :query_selected_systems, fn _prob, _ids, _opts ->
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
      text = text_of(result)
      assert String.contains?(text, "Error:")
      refute text == "Unknown tool: compare_provers"
    end

    test "missing problem returns a descriptive error" do
      result = tool_call(62, "compare_provers", %{"system_ids" => ["E---2.0"]})
      text = text_of(result)
      assert String.contains?(text, "Error:")
      refute text == "Unknown tool: compare_provers"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Sends a raw string (not a map) through handle_rpc, used for malformed JSON.
  defp rpc_raw(raw_string) do
    case AtpMcp.handle_rpc(raw_string) do
      nil -> :silent
      json -> {:ok, Jason.decode!(json)}
    end
  end
end
