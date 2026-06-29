defmodule AtpMcp.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/jcschuster/AtpMcp"

  def project do
    [
      app: :atp_mcp,
      version: @version,
      elixir: "~> 1.20",
      deps: deps(),
      escript: escript(),
      # Hex metadata
      description:
        "MCP server exposing the SystemOnTPTP, StarExec, Isabelle and LocalExec " <>
          "theorem-prover backends from AtpClient over stdio JSON-RPC.",
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
      {:atp_client, "~> 0.4"},
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
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/v#{@version}/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
