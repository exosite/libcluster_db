defmodule LibclusterDB.Mixfile do
  use Mix.Project

  def project do
    [app: :libcluster_db,
     version: "0.5.2",
     elixir: "~> 1.4",
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
      {:mongodb_driver, "~> 1.0"},
    ]
  end
end
