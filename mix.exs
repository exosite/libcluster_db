defmodule LibclusterDB.Mixfile do
  use Mix.Project

  def project do
    [app: :libcluster_db,
     version: "0.5.0",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  def application do
    [applications: [],
     extra_applications: [:logger]]
  end

  defp deps do
    [
      {:libcluster, "~> 3.0"},
      {:mongodb, "~> 0.5"}
    ]
  end
end
