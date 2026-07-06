defmodule HSM.MixProject do
  use Mix.Project

  def project do
    [
      app: :hsm,
      version: "1.3.1",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: [],
      name: "HSM",
      description: "Hierarchical state machine DSL/runtime for Elixir.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/stateforward/hsm.ex"}
      ],
      source_url: "https://github.com/stateforward/hsm.ex"
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger]
    ]
  end
end
