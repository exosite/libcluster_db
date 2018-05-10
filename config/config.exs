# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
use Mix.Config

config :libcluster,
  topologies: [
    example: [
      strategy: ClusterDB.Strategy.Mongo,
      config: [
        mongodb: [
          url: "mongodb://localhost:27017/node_status",
          type: :unknown,
          pool_handler: DBConnection.Poolboy,
          collection_name: "node_status"
        ],
        heartbeat: [interval: 1000, delay_tolerance: 1000],
      ],
    ]
  ]
