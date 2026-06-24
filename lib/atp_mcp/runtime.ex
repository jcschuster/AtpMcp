defmodule AtpMcp.Runtime do
  @moduledoc """
  GenServer that drives the MCP protocol loop: owns stdout, runs each
  `tools/call` in its own Task, and handles `notifications/cancelled`.

  ## Why a process

  The synchronous `AtpMcp.handle_rpc/1` path is fine for tests but
  insufficient at runtime for two reasons:

    1. **Cancellation.** While a tool call is in flight, the server must
       still read further stdin lines so a `notifications/cancelled` can
       interrupt it. That requires the tool's work to run in a separate
       process the dispatcher can kill.
    2. **Progress.** Long-running tools should emit periodic
       `notifications/progress` frames when the client supplied a
       `_meta.progressToken`. Multiple processes therefore need to write
       to stdout — and the writes must not interleave.

  This GenServer is the only owner of stdout. Tool calls run in
  short-lived Tasks; their results flow back through the GenServer's
  mailbox and are serialized onto stdout in arrival order.

  ## Cancellation semantics

  `Process.exit(task_pid, :kill)` is the cancellation signal. Per
  `AtpClient.Backend`'s contract, each backend treats death of the
  calling process as a request to abort and tears down the upstream
  work it owns. In practice:

    * **LocalExec** — the spawned `Port` is closed, which SIGKILLs the
      prover binary; a small guard process also catches edge cases by
      SIGKILLing the OS pid directly.
    * **StarExec** — a cancel-guard process issues `DELETE` against the
      remote job before letting go.
    * **Isabelle** — the session is torn down, which drops any in-flight
      `use_theories` task on the server side. The next call pays the
      session-start cost again (typically a few seconds for `HOL`).
    * **SystemOnTPTP** — the local `Req`/`Finch` request errors out and
      the connection slot is released, but the **remote prover keeps
      running to its `TimeLimit`**. SOTPTP has no remote-cancel
      endpoint; `:time_limit_sec` is the only server-side bound.

  The MCP response is suppressed in all four cases as the spec
  requires.

  ## Progress semantics

  When a `tools/call` carries `_meta.progressToken`, the Task emits a
  `notifications/progress` frame every `:heartbeat_ms` (default 5000)
  while the work is in flight. The `progress` field is the elapsed
  whole seconds; `total` is omitted because most ATP runs have no
  meaningful upper bound. Real per-step progress would require
  AtpClient changes (e.g. streaming `query_selected_systems`).
  """

  use GenServer

  @default_heartbeat_ms 5_000

  defmodule Entry do
    @moduledoc false
    @enforce_keys [:task_pid, :monitor_ref]
    defstruct [:task_pid, :monitor_ref, :progress_token]
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Hand a raw stdin line to the runtime. Returns immediately; the runtime
  decodes, dispatches, and (for `tools/call`) spawns a Task.
  """
  @spec deliver(String.t(), GenServer.server()) :: :ok
  def deliver(line, server \\ __MODULE__), do: GenServer.cast(server, {:deliver, line})

  @doc """
  Write an arbitrary already-encoded line to the runtime's output sink.
  Primarily for tests; production paths flow through `deliver/2`.
  """
  @spec write(String.t(), GenServer.server()) :: :ok
  def write(line, server \\ __MODULE__), do: GenServer.cast(server, {:write, line})

  @doc """
  Block until the runtime has drained its current cast backlog. Useful
  in tests after delivering a cancellation to confirm the kill has been
  processed before asserting that no response was written.
  """
  @spec sync(GenServer.server()) :: :ok
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  @doc """
  Block until the runtime has no in-flight `tools/call` tasks. Called
  by `AtpMcp.main/1` after stdin closes so pending tool responses
  reach stdout before the BEAM exits.
  """
  @spec await_idle(GenServer.server(), non_neg_integer()) :: :ok
  def await_idle(server \\ __MODULE__, poll_ms \\ 25) do
    case GenServer.call(server, :inflight_count) do
      0 ->
        :ok

      _ ->
        Process.sleep(poll_ms)
        await_idle(server, poll_ms)
    end
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    state = %{
      io: Keyword.get(opts, :io, :stdio),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, @default_heartbeat_ms),
      by_id: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:deliver, line}, state) do
    case String.trim(line) do
      "" -> {:noreply, state}
      trimmed -> handle_line(trimmed, state)
    end
  end

  @impl true
  def handle_cast({:write, line}, state) do
    write_line(state.io, line)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:progress, token, value, message}, state) when not is_nil(token) do
    base = %{progressToken: token, progress: value}
    params = if message, do: Map.put(base, :message, message), else: base
    frame = %{jsonrpc: "2.0", method: "notifications/progress", params: params}
    write_line(state.io, Jason.encode!(frame))
    {:noreply, state}
  end

  def handle_cast({:progress, _nil_token, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call(:inflight_count, _from, state),
    do: {:reply, map_size(state.by_id), state}

  @impl true
  def handle_info({:tool_complete, id, response}, state) do
    case Map.pop(state.by_id, id) do
      {nil, _} ->
        # Cancelled (or already cleaned up); drop the response.
        {:noreply, state}

      {entry, rest} ->
        Process.demonitor(entry.monitor_ref, [:flush])
        write_line(state.io, Jason.encode!(response))
        {:noreply, %{state | by_id: rest}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pop_by_ref(state.by_id, ref) do
      {nil, _} ->
        {:noreply, state}

      {{id, _entry}, rest} ->
        maybe_report_crash(state.io, id, reason)
        {:noreply, %{state | by_id: rest}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Kill any still-running tool tasks so they don't outlive us with
    # half-written stdout. We're already terminating; ignoring exit
    # signals here is fine.
    Enum.each(state.by_id, fn {_id, entry} ->
      Process.exit(entry.task_pid, :kill)
    end)

    :ok
  end

  # --- Dispatch ---

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, _} ->
        write_line(state.io, Jason.encode!(AtpMcp.parse_error()))
        {:noreply, state}
    end
  end

  defp handle_message(message, state) do
    case AtpMcp.classify(message) do
      {:reply, response} ->
        write_line(state.io, Jason.encode!(response))
        {:noreply, state}

      {:tool_call, id, name, args, token} ->
        {:noreply, start_tool_call(id, name, args, token, state)}

      {:cancel, id} ->
        {:noreply, cancel(id, state)}

      :noop ->
        {:noreply, state}
    end
  end

  defp start_tool_call(id, name, args, token, state) do
    runtime = self()
    heartbeat_ms = state.heartbeat_ms

    {task_pid, monitor_ref} =
      spawn_monitor(fn -> run_tool(runtime, id, name, args, token, heartbeat_ms) end)

    entry = %Entry{task_pid: task_pid, monitor_ref: monitor_ref, progress_token: token}
    %{state | by_id: Map.put(state.by_id, id, entry)}
  end

  defp cancel(id, state) do
    case Map.pop(state.by_id, id) do
      {nil, _} ->
        state

      {entry, rest} ->
        # Demonitor first so the impending DOWN doesn't trigger our crash
        # reporter; then kill. Order matters.
        Process.demonitor(entry.monitor_ref, [:flush])
        Process.exit(entry.task_pid, :kill)
        %{state | by_id: rest}
    end
  end

  # --- Task body ---

  defp run_tool(runtime, id, name, args, token, heartbeat_ms) do
    worker = Task.async(fn -> AtpMcp.execute_tool(name, args) end)
    content = await_with_heartbeat(worker, token, runtime, heartbeat_ms, 0)
    send(runtime, {:tool_complete, id, AtpMcp.tool_response(id, content)})
  end

  defp await_with_heartbeat(worker, nil, _runtime, _interval, _elapsed) do
    Task.await(worker, :infinity)
  end

  defp await_with_heartbeat(worker, token, runtime, interval, elapsed) do
    case Task.yield(worker, interval) do
      {:ok, content} ->
        content

      nil ->
        new_elapsed = elapsed + interval
        seconds = div(new_elapsed, 1000)
        GenServer.cast(runtime, {:progress, token, seconds, "running (#{seconds}s)"})
        await_with_heartbeat(worker, token, runtime, interval, new_elapsed)
    end
  end

  # --- Helpers ---

  # `IO.binwrite` to match `main/1`'s latin1 encoding setopt — JSON-RPC is
  # bytes, not Elixir-encoded strings.
  defp write_line(:stdio, line), do: IO.binwrite([line, "\n"])
  defp write_line(pid, line) when is_pid(pid), do: send(pid, {:io_write, line})
  defp write_line(device, line), do: IO.binwrite(device, [line, "\n"])

  defp pop_by_ref(by_id, ref) do
    case Enum.find(by_id, fn {_, entry} -> entry.monitor_ref == ref end) do
      nil -> {nil, by_id}
      {id, entry} -> {{id, entry}, Map.delete(by_id, id)}
    end
  end

  defp maybe_report_crash(_io, _id, :normal), do: :ok
  defp maybe_report_crash(_io, _id, :killed), do: :ok
  defp maybe_report_crash(_io, _id, :shutdown), do: :ok

  defp maybe_report_crash(io, id, reason) do
    response = %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32_603, message: "Internal error: #{inspect(reason)}"}
    }

    write_line(io, Jason.encode!(response))
  end
end
