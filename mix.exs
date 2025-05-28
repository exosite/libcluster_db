defmodule LibclusterDB.Mixfile do
  use Mix.Project

  def project do
    [app: :libcluster_db,
     version: "0.6.3",
     elixir: "~> 1.17",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:libcluster, "~> 3.0"},
      {:mongodb_driver, "~> 1.5"}
    ]
  end
end
