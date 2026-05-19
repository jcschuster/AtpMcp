Mox.defmock(AtpMcp.MockAtp, for: AtpMcp.AtpBehaviour)
Application.put_env(:atp_mcp, :atp_client, AtpMcp.MockAtp)
ExUnit.start()
