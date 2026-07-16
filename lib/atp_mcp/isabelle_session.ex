defmodule AtpMcp.IsabelleSession do
  @moduledoc """
  Long-lived Isabelle session shared across every `prove_isabelle` and
  `query_backend backend: "isabelle"` call for the lifetime of the MCP
  server.

  The first isabelle call pays the ~seconds `HOL` session-start cost;
  subsequent calls reuse the open session. If the underlying session
  dies (Isabelle crash, network drop), the next call transparently
  opens a fresh one.

  Drop-in for `AtpClient.Isabelle` in `AtpMcp`'s backends map: exposes
  the same `query/2`, `prove_theory/3`, `verify/1`, and `label/0` entry
  points the tool dispatch in `AtpMcp` calls, so no call site changes.

  ## Concurrency

  Calls serialise through this GenServer's mailbox. `IsabelleClient.Shared`
  can only run one `use_theories` at a time per session anyway, so
  serialising at this level is not a throughput loss and keeps the
  session state simple.

  ## Cancellation

  When `AtpMcp.Runtime` kills a tool-call Task, this GenServer keeps
  processing the in-flight `use_theories` on behalf of the (now dead)
  caller. The reply is discarded and the session stays warm for the
  next call. Isabelle has no remote-cancel endpoint, so the theory
  runs to completion server-side either way; killing the session
  would only add a session-restart penalty and disrupt concurrent
  calls.
  """

  use GenServer
  @behaviour AtpMcp.Backends.Isabelle

  alias AtpClient.Isabelle

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl AtpMcp.Backends.Isabelle
  def label, do: Isabelle.label()

  @impl AtpMcp.Backends.Isabelle
  def verify(_opts), do: GenServer.call(__MODULE__, :verify, :infinity)

  @impl AtpMcp.Backends.Isabelle
  def query(problem, opts),
    do: GenServer.call(__MODULE__, {:query, problem, opts}, :infinity)

  @impl AtpMcp.Backends.Isabelle
  def prove_theory(theory, name, opts),
    do: GenServer.call(__MODULE__, {:prove_theory, theory, name, opts}, :infinity)

  # --- Callbacks ---

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{session: nil}}
  end

  @impl GenServer
  def handle_call(:verify, _from, state) do
    case ensure_session(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:prove_theory, theory, name, opts}, _from, state) do
    with_session(state, opts, fn session, session_opts ->
      Isabelle.prove_theory(session, theory, name, session_opts)
    end)
  end

  def handle_call({:query, problem, opts}, _from, state) do
    with_session(state, opts, fn session, session_opts ->
      case Isabelle.prove_tptp(session, problem, session_opts) do
        {:ok, lemmas} -> aggregate_lemma_results(lemmas)
        {:error, _} = err -> err
      end
    end)
  end

  @impl GenServer
  def terminate(_reason, %{session: nil}), do: :ok

  def terminate(_reason, %{session: session}) do
    Isabelle.close_session(session)
    :ok
  end

  # --- Internals ---

  # Serves one call: (re)opens the session if needed, runs `fun`, and drops
  # the cached session if `fun` exits (session process died mid-call).
  defp with_session(state, opts, fun) do
    case ensure_session(state) do
      {:ok, %{session: session} = new_state} ->
        try do
          {:reply, fun.(session, opts), new_state}
        catch
          :exit, reason ->
            {:reply, {:error, {:session_down, reason}}, %{new_state | session: nil}}
        end

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  defp ensure_session(%{session: session} = state) when not is_nil(session) do
    if session_alive?(session),
      do: {:ok, state},
      else: ensure_session(%{state | session: nil})
  end

  defp ensure_session(state) do
    case Isabelle.open_session([]) do
      {:ok, session} -> {:ok, %{state | session: session}}
      {:error, reason} -> {:error, reason, state}
    end
  rescue
    # `AtpClient.Config` signals missing/invalid settings by raising rather
    # than returning {:error, _}. Letting that escape would terminate this
    # GenServer -- and, since it is linked to the escript's main process,
    # the whole MCP server along with it. Report it to the caller instead.
    e -> {:error, {:config_error, Exception.message(e)}, state}
  end

  defp session_alive?(session) do
    session |> Isabelle.Session.client() |> Process.alive?()
  end

  # Weakest-link aggregation mirroring `AtpClient.Isabelle.query/2`'s
  # private aggregator — any non-`{:ok, :theorem}` lemma decides the
  # collapsed verdict.
  defp aggregate_lemma_results([]), do: {:ok, :gave_up}

  defp aggregate_lemma_results(lemmas) do
    Enum.find_value(lemmas, {:ok, :theorem}, fn %{result: r} ->
      if r != {:ok, :theorem}, do: r
    end)
  end
end
