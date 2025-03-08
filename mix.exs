defmodule WiiScanner.MixProject do
  use Mix.Project

  def project do
    [
      app: :wii_scanner,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Collector.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:codepagex, "~> 0.1.6"}
    ]
  end
end
