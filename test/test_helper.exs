Mox.defmock(AtpMcp.MockSotptp, for: AtpMcp.Backends.SystemOnTptp)
Mox.defmock(AtpMcp.MockIsabelle, for: AtpMcp.Backends.Isabelle)
Mox.defmock(AtpMcp.MockLocalExec, for: AtpMcp.Backends.LocalExec)
Mox.defmock(AtpMcp.MockStarExec, for: AtpMcp.Backends.StarExec)
Mox.defmock(AtpMcp.MockLint, for: AtpMcp.Backends.Lint)

Application.put_env(:atp_mcp, :sotptp_backend, AtpMcp.MockSotptp)
Application.put_env(:atp_mcp, :isabelle_backend, AtpMcp.MockIsabelle)
Application.put_env(:atp_mcp, :local_exec_backend, AtpMcp.MockLocalExec)
Application.put_env(:atp_mcp, :starexec_backend, AtpMcp.MockStarExec)
Application.put_env(:atp_mcp, :lint_backend, AtpMcp.MockLint)

ExUnit.start()
