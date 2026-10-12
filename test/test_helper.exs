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
