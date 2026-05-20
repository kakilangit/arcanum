defmodule Arcanum.MixProject do
  use Mix.Project

  @version "0.1.3"
  @source_url "https://github.com/kakilangit/arcanum"

  def project do
    [
      app: :arcanum,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Provider-agnostic AI inference library for Elixir. " <>
      "Adapters for OpenAI-compatible APIs (DeepSeek, Z.AI/Zhipu, OpenRouter, Ollama)."
  end

  defp package do
    [
      name: "arcanum",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Arcanum",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp aliases do
    [
      lint: [
        "format --check-formatted",
        "credo --strict",
        "compile --warnings-as-errors"
      ]
    ]
  end
end
