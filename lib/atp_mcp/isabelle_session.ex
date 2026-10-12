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

  ## Which server

  With `config :atp_client, :isabelle, password: …` set, the session
  connects to that server (`host`/`port` from the same config). Without a
  password, and with `isabelle` on `PATH`, it starts a resident server
  named `atp_mcp` on a free port — or reuses one that is already running
  under that name — and connects to it. The server outlives the MCP
  process, so the next start skips the JVM spin-up; stop it with
  `isabelle server -n atp_mcp -x`. Set `config :atp_mcp,
  isabelle_autostart: false` to require a configured server.

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

  @server_name "atp_mcp"

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
      Isabelle.prove_tptp(session, problem, session_opts)
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
    with {:ok, opts} <- server_opts(),
         {:ok, session} <- Isabelle.open_session(opts) do
      {:ok, %{state | session: session}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  rescue
    # `AtpClient.Config` signals missing/invalid settings by raising rather
    # than returning {:error, _}. Letting that escape would terminate this
    # GenServer -- and, since it is linked to the escript's main process,
    # the whole MCP server along with it. Report it to the caller instead.
    e -> {:error, {:config_error, Exception.message(e)}, state}
  end

  # A configured password names a server someone else runs; without one, run
  # our own. Re-running `isabelle server -n atp_mcp` against a live server
  # only prints its coordinates, so this is also how a restarted MCP process
  # finds the server it left behind.
  defp server_opts do
    case AtpClient.Config.fetch(:isabelle, :password, nil) do
      nil -> local_server(Application.get_env(:atp_mcp, :isabelle_autostart, true))
      _password -> {:ok, []}
    end
  end

  # With auto-start off, `open_session/1` reports the missing password.
  defp local_server(false), do: {:ok, []}

  defp local_server(true) do
    case IsabelleClient.start_server(server_name: @server_name, server_port: 0) do
      {:ok, server} ->
        {:ok, [host: server.host, port: server.port, password: server.password]}

      {:error, :isabelle_not_found} ->
        {:error,
         {:no_isabelle_server,
          "no `password` under `config :atp_client, :isabelle`, and no `isabelle` " <>
            "on PATH to start a server with"}}

      {:error, reason} ->
        {:error, {:isabelle_server_start_failed, reason}}
    end
  end

  defp session_alive?(session) do
    session |> Isabelle.Session.client() |> Process.alive?()
  end
end
