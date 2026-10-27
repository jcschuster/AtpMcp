Mox.defmock(AtpMcp.MockSotptp, for: AtpMcp.Backends.SystemOnTptp)
Mox.defmock(AtpMcp.MockIsabelle, for: AtpMcp.Backends.Isabelle)
Mox.defmock(AtpMcp.MockLocalExec, for: AtpMcp.Backends.LocalExec)
Mox.defmock(AtpMcp.MockStarExec, for: AtpMcp.Backends.StarExec)
Mox.defmock(AtpMcp.MockTptp4x, for: Tptp.Analyzer)

Application.put_env(:atp_mcp, :backends, %{
  "sotptp" => AtpMcp.MockSotptp,
  "isabelle" => AtpMcp.MockIsabelle,
  "local_exec" => AtpMcp.MockLocalExec,
  "starexec" => AtpMcp.MockStarExec
})

Application.put_env(:atp_mcp, :tptp4x, AtpMcp.MockTptp4x)

defmodule AtpMcp.TestSupport do
  @moduledoc false

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  @doc "`request` with the `_meta` every MCP 2026-07-28 request carries; notifications as they are."
  def modern(%{"id" => _} = request) do
    Map.update(request, "params", %{"_meta" => @meta}, fn params ->
      Map.update(params, "_meta", @meta, &Map.merge(@meta, &1))
    end)
  end

  def modern(notification), do: notification

  @doc "A backend result carrying `status`, as every `query` returns since AtpClient 0.7."
  def result(status, output \\ "") do
    %AtpClient.Result{
      status: status,
      evidence: :szs,
      output: output,
      backend: AtpClient.SystemOnTptp
    }
  end
end

ExUnit.start()
