defmodule AtpMcp.RuntimeTest do
  # Not async: Runtime is a singleton (named registration), and Mox runs in
  # global mode so the spawned Task can see expectations from the test pid.
  use ExUnit.Case, async: false

  import Mox

  alias AtpMcp.Runtime

  @problem "fof(ax,axiom,p). fof(conj,conjecture,p)."

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup ctx do
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Runtime.start_link(
        name: name,
        io: self(),
        heartbeat_ms: Map.get(ctx, :heartbeat_ms, 50)
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, runtime: name}
  end

  defp deliver(runtime, msg), do: Runtime.deliver(Jason.encode!(msg), runtime)

  defp assert_response(id, runtime) do
    Runtime.sync(runtime)
    assert_receive {:io_write, line}, 500
    response = Jason.decode!(line)
    assert response["id"] == id
    response
  end

  # ---------------------------------------------------------------------------
  # Synchronous methods still flow through the runtime
  # ---------------------------------------------------------------------------

  describe "synchronous protocol methods" do
    test "initialize is written immediately", %{runtime: runtime} do
      deliver(runtime, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})

      response = assert_response(1, runtime)
      assert response["result"]["protocolVersion"] == "2025-11-25"
    end

    test "tools/list is written immediately", %{runtime: runtime} do
      deliver(runtime, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      response = assert_response(2, runtime)
      assert is_list(response["result"]["tools"])
    end

    test "notifications/initialized produces no output", %{runtime: runtime} do
      deliver(runtime, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      Runtime.sync(runtime)
      refute_received {:io_write, _}
    end

    test "malformed JSON produces a parse-error response", %{runtime: runtime} do
      Runtime.deliver("{not json}", runtime)
      response = assert_response(nil, runtime)
      assert response["error"]["code"] == -32_700
    end
  end

  # ---------------------------------------------------------------------------
  # Tool calls run in a Task
  # ---------------------------------------------------------------------------

  describe "tools/call" do
    test "writes the tool response when the task completes", %{runtime: runtime} do
      expect(AtpMcp.MockSotptp, :list_provers, fn -> ["E---2.0"] end)

      deliver(runtime, %{
        "jsonrpc" => "2.0",
        "id" => 10,
        "method" => "tools/call",
        "params" => %{"name" => "list_provers", "arguments" => %{}}
      })

      response = assert_response(10, runtime)
      assert hd(response["result"]["content"])["text"] == "E---2.0"
    end

    test "two concurrent calls both produce responses (no interleaved frames)",
         %{runtime: runtime} do
      # Each mock waits for the test to release it.
      test_pid = self()

      expect(AtpMcp.MockSotptp, :list_provers, 2, fn ->
        send(test_pid, {:mock_started, self()})
        receive do
          {:proceed, value} -> value
        end
      end)

      for id <- [20, 21] do
        deliver(runtime, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "tools/call",
          "params" => %{"name" => "list_provers", "arguments" => %{}}
        })
      end

      assert_receive {:mock_started, pid_a}, 500
      assert_receive {:mock_started, pid_b}, 500

      send(pid_a, {:proceed, ["E---2.0"]})
      send(pid_b, {:proceed, ["Vampire---4.5"]})

      messages =
        for _ <- 1..2 do
          assert_receive {:io_write, line}, 500
          Jason.decode!(line)
        end

      ids = messages |> Enum.map(& &1["id"]) |> Enum.sort()
      assert ids == [20, 21]
    end
  end

  # ---------------------------------------------------------------------------
  # Cancellation
  # ---------------------------------------------------------------------------

  describe "notifications/cancelled" do
    test "kills the in-flight task and suppresses the response", %{runtime: runtime} do
      test_pid = self()

      expect(AtpMcp.MockSotptp, :list_provers, fn ->
        send(test_pid, {:mock_started, self()})

        receive do
          :go -> ["never delivered"]
        end
      end)

      deliver(runtime, %{
        "jsonrpc" => "2.0",
        "id" => 30,
        "method" => "tools/call",
        "params" => %{"name" => "list_provers", "arguments" => %{}}
      })

      assert_receive {:mock_started, mock_pid}, 500
      mock_ref = Process.monitor(mock_pid)

      deliver(runtime, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 30}
      })

      Runtime.sync(runtime)

      # The Task (and the Mox lambda running inside it) is killed.
      assert_receive {:DOWN, ^mock_ref, :process, ^mock_pid, _reason}, 500

      # No response written for the cancelled request.
      refute_receive {:io_write, _}, 100
    end

    test "cancelling an unknown id is a no-op", %{runtime: runtime} do
      deliver(runtime, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 999}
      })

      Runtime.sync(runtime)
      refute_received {:io_write, _}
    end

    test "cancellation arriving after the task naturally completed is harmless",
         %{runtime: runtime} do
      expect(AtpMcp.MockSotptp, :list_provers, fn -> ["E---2.0"] end)

      deliver(runtime, %{
        "jsonrpc" => "2.0",
        "id" => 31,
        "method" => "tools/call",
        "params" => %{"name" => "list_provers", "arguments" => %{}}
      })

      _ = assert_response(31, runtime)

      deliver(runtime, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 31}
      })

      Runtime.sync(runtime)
      refute_received {:io_write, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Progress
  # ---------------------------------------------------------------------------

  describe "_meta.progressToken" do
    test "emits notifications/progress while the task runs", %{runtime: runtime} do
      test_pid = self()

      expect(AtpMcp.MockSotptp, :query_system, fn _, _, _ ->
        send(test_pid, {:mock_started, self()})

        receive do
          :go -> {:ok, :thm}
        end
      end)

      deliver(runtime, %{
        "jsonrpc" => "2.0",
        "id" => 40,
        "method" => "tools/call",
        "params" => %{
          "name" => "run_prover",
          "arguments" => %{"problem" => @problem, "system_id" => "E---2.0"},
          "_meta" => %{"progressToken" => "tok-40"}
        }
      })

      assert_receive {:mock_started, mock_pid}, 500

      # At heartbeat_ms = 50ms, expect a progress notification within 200ms.
      assert_receive {:io_write, line}, 500
      frame = Jason.decode!(line)
      assert frame["method"] == "notifications/progress"
      assert frame["params"]["progressToken"] == "tok-40"
      assert frame["params"]["progress"] >= 0
      assert is_binary(frame["params"]["message"])

      send(mock_pid, :go)

      response = assert_response(40, runtime)
      assert hd(response["result"]["content"])["text"] == "Theorem"
    end

    @tag heartbeat_ms: 50
    test "without a progress token, no progress notifications are emitted",
         %{runtime: runtime} do
      test_pid = self()

      expect(AtpMcp.MockSotptp, :query_system, fn _, _, _ ->
        send(test_pid, {:mock_started, self()})
        # Sleep longer than the heartbeat to give a stray emit a chance to
        # arrive.
        Process.sleep(150)
        {:ok, :thm}
      end)

      deliver(runtime, %{
        "jsonrpc" => "2.0",
        "id" => 41,
        "method" => "tools/call",
        "params" => %{
          "name" => "run_prover",
          "arguments" => %{"problem" => @problem, "system_id" => "E---2.0"}
        }
      })

      assert_receive {:mock_started, _mock_pid}, 500

      # Only the final response should be received; no progress frames.
      assert_receive {:io_write, line}, 1000
      frame = Jason.decode!(line)
      assert frame["id"] == 41
      refute frame["method"] == "notifications/progress"

      refute_received {:io_write, _}
    end
  end

end
