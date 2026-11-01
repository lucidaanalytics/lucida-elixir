defmodule Lucida.MixProject do
  use Mix.Project

  def project do
    [
      app: :lucida,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: [],
      description: "Lucida server SDK: capture, batched delivery, local feature-flag evaluation",
      source_url: "https://github.com/lucidaanalytics/lucida-elixir",
      package: package()
    ]
  end

  # :crypto for SHA-256, :inets/:ssl/:public_key for the :httpc adapter. No hex deps.
  def application, do: [extra_applications: [:logger, :crypto, :inets, :ssl, :public_key]]

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/lucidaanalytics/lucida-elixir"},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
