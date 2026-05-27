defmodule HSM.MixProject do
  use Mix.Project

  def project do
    [
      app: :hsm,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: [],
      name: "HSM",
      description: "Hierarchical state machine DSL/runtime for Elixir.",
      source_url: "https://github.com/stateforward/hsm.ex"
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger]
    ]
  end
end
