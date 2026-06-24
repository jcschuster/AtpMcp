Mox.defmock(AtpMcp.MockSotptp, for: AtpMcp.Backends.SystemOnTptp)
Mox.defmock(AtpMcp.MockIsabelle, for: AtpMcp.Backends.Isabelle)
Mox.defmock(AtpMcp.MockLocalExec, for: AtpMcp.Backends.LocalExec)
Mox.defmock(AtpMcp.MockStarExec, for: AtpMcp.Backends.StarExec)
Mox.defmock(AtpMcp.MockLint, for: AtpMcp.Backends.Lint)

Application.put_env(:atp_mcp, :backends, %{
  "sotptp" => AtpMcp.MockSotptp,
  "isabelle" => AtpMcp.MockIsabelle,
  "local_exec" => AtpMcp.MockLocalExec,
  "starexec" => AtpMcp.MockStarExec
})

Application.put_env(:atp_mcp, :lint, AtpMcp.MockLint)

ExUnit.start()
