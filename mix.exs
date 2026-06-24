defmodule AtpMcp.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/jcschuster/AtpMcp"

  def project do
    [
      app: :atp_mcp,
      version: @version,
      elixir: "~> 1.20",
      deps: deps(),
      escript: escript(),
      # Hex metadata
      description: "MCP server exposing SystemOnTPTP theorem provers to Claude Code",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp escript do
    [main_module: AtpMcp, name: "atp_mcp"]
  end

  defp deps do
    [
      {:atp_client, github: "jcschuster/AtpClient"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
