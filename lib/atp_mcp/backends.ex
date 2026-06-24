defmodule AtpMcp.Backends do
  @moduledoc """
  Per-backend behaviours used by `AtpMcp` for dependency injection.

  Each behaviour exposes only the surface `AtpMcp` actually calls — enough
  for Mox to stand in for the real `AtpClient.*` module in tests.
  """
end

defmodule AtpMcp.Backends.SystemOnTptp do
  @moduledoc false
  @callback list_provers() :: [String.t()]
  @callback query(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback query_system(String.t(), String.t(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback query_selected_systems(String.t(), [String.t()], keyword()) ::
              {:ok, [{String.t(), {:ok, term()} | {:error, term()}}]} | {:error, term()}
  @callback verify(keyword()) :: :ok | {:error, term()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.Isabelle do
  @moduledoc false
  @callback query(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback query(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback verify(keyword()) :: :ok | {:error, term()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.LocalExec do
  @moduledoc false
  @callback query(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback verify(keyword()) :: :ok | {:error, term()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.StarExec do
  @moduledoc false
  @callback query(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback verify(keyword()) :: :ok | {:error, term()}
  @callback label() :: String.t()
end

defmodule AtpMcp.Backends.Lint do
  @moduledoc false
  @callback analyze(String.t(), keyword()) :: AtpClient.Lint.Report.t()
end
