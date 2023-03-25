defmodule LibclusterDB.Mixfile do
  use Mix.Project

  def project do
    [
      app: :libcluster_db,
      version: "0.6.0",
      elixir: "~> 1.4",
      dialyzer: [plt_add_deps: :app_tree],
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:libcluster, "~> 3.0"},
      {:mongodb_driver, "~> 1.0"}
    ]
  end
end
