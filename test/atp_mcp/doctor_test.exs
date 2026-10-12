defmodule AtpMcp.DoctorTest do
  # Reads and writes the global application env, as AtpMcp.SettingsTest does.
  use ExUnit.Case, async: false
  import Mox
  import ExUnit.CaptureIO

  alias AtpMcp.Doctor

  setup :verify_on_exit!

  @backends %{"sotptp" => AtpMcp.MockSotptp, "starexec" => AtpMcp.MockStarExec}

  defp run(names) do
    with_io(fn -> Doctor.run(names, @backends, "/cfg/atp_mcp.exs", "9.9.9") end)
  end

  test "reports version, config file, settings, and checks; :ok when all pass" do
    expect(AtpMcp.MockSotptp, :label, fn -> "SystemOnTPTP" end)
    expect(AtpMcp.MockSotptp, :verify, fn [] -> :ok end)

    {outcome, out} = run(["sotptp"])

    assert outcome == :ok
    assert out =~ "atp_mcp 9.9.9"
    assert out =~ "config file: /cfg/atp_mcp.exs"
    assert out =~ "sotptp - SystemOnTPTP"
    assert out =~ ~s|  url: "https://tptp.org/cgi-bin/SystemOnTPTPFormReply"|
    assert out =~ "  check: OK"
  end

  test "checks every backend when none are named, and fails if one fails" do
    expect(AtpMcp.MockSotptp, :label, fn -> "SystemOnTPTP" end)
    expect(AtpMcp.MockSotptp, :verify, fn _ -> :ok end)
    expect(AtpMcp.MockStarExec, :label, fn -> "StarExec" end)
    expect(AtpMcp.MockStarExec, :verify, fn _ -> {:error, :econnrefused} end)

    {outcome, out} = run([])

    assert outcome == :error
    assert out =~ "check: Error: :econnrefused"
  end

  test "a backend that raises on missing settings is reported, not fatal" do
    expect(AtpMcp.MockStarExec, :label, fn -> "StarExec" end)

    expect(AtpMcp.MockStarExec, :verify, fn _ ->
      raise ArgumentError, "AtpClient: missing required setting `:base_url`.\n\nmore help"
    end)

    {outcome, out} = run(["starexec"])

    assert outcome == :error
    assert out =~ "check: Error: AtpClient: missing required setting `:base_url`."
    refute out =~ "more help"
  end

  test "passwords are shown only as set or unset" do
    Application.put_env(:atp_client, :starexec, password: "hunter2")
    on_exit(fn -> Application.delete_env(:atp_client, :starexec) end)

    expect(AtpMcp.MockStarExec, :label, fn -> "StarExec" end)
    expect(AtpMcp.MockStarExec, :verify, fn _ -> :ok end)

    {_, out} = run(["starexec"])

    assert out =~ "  password: (set)"
    assert out =~ "  username: (unset)"
    refute out =~ "hunter2"
  end

  test "an unknown backend name is a failed check" do
    {outcome, out} = run(["bogus"])
    assert outcome == :error
    assert out =~ "bogus\n  check: unknown backend"
  end
end
