defmodule AtpMcp.Backends do
  @moduledoc """
  Per-backend behaviours used by `AtpMcp` for dependency injection.

  Each behaviour exposes only the surface `AtpMcp` actually calls — enough
  for Mox to stand in for the real `AtpClient.*` module in tests. The remote
  lint pass needs no behaviour of its own: it is a `Tptp.Analyzer`.
  """

  @type result :: {:ok, AtpClient.Result.t()} | {:error, term()}
end

defmodule AtpMcp.Backends.SystemOnTptp do
  @moduledoc false
  @callback systems(keyword()) :: [AtpClient.System.t()]
  @callback query(AtpClient.Input.t(), keyword()) :: AtpMcp.Backends.result()
  @callback query_system(AtpClient.Input.t(), String.t(), keyword()) ::
              AtpMcp.Backends.result()
  @callback query_selected_systems(AtpClient.Input.t(), [String.t()], keyword()) ::
              {:ok, [{String.t(), AtpMcp.Backends.result()}]} | {:error, term()}
  @callback verify(keyword()) :: :ok | {:error, term()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.Isabelle do
  @moduledoc false
  @callback query(AtpClient.Input.t(), keyword()) :: AtpMcp.Backends.result()
  @callback prove_theory(String.t(), String.t(), keyword()) :: AtpMcp.Backends.result()
  @callback verify(keyword()) :: :ok | {:error, term()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.LocalExec do
  @moduledoc false
  @callback query(AtpClient.Input.t(), keyword()) :: AtpMcp.Backends.result()
  @callback verify(keyword()) :: :ok | {:error, term()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.StarExec do
  @moduledoc false
  @callback query(AtpClient.Input.t(), keyword()) :: AtpMcp.Backends.result()
  @callback verify(keyword()) :: :ok | {:error, term()}
  @callback label() :: String.t()
end
