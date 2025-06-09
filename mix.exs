defmodule Collector.MixProject do
  use Mix.Project

  def project do
    [
      app: :collector,
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
      {:codepagex, "~> 0.1.6"},
      {:redix, "~> 1.2"},
      {:ex_aws, "~> 2.0"},
      {:ex_aws_s3, "~> 2.0"},
      {:poison, "~> 3.0"},
      {:hackney, "~> 1.9"},
      {:req, "~> 0.5.0"},
      {:dotenv, "~> 3.0.0", only: [:dev, :test]},
      {:uuid, "~> 1.1"},
      {:phoenix_client, "~> 0.3"}
    ]
  end
end
