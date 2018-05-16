# LibclusterDB

Automatic cluster formation/healing for Elixir applications using database heartbeat.

This is a database heartbeat strategy for [libcluster](https://hexdocs.pm/libcluster/). It currently supports identifying nodes based on Mongodb.

## Installation

```elixir
def application do
  [
    applications: [
      :libcluster_db,
      ...
    ],
  ...
  ]

def deps do
  [{:libcluster_db, github: "exosite/libcluster_db", branch: "master"}]
end
```

## An example configuration

The configuration for libcluster_db can also be described as a spec for the clustering topologies and strategies which will be used. (Now only Mongodb heartbeat implementation.)

### Mongodb
Mongodb heartbeat implementation. We support this format to get the setting values from environment variables. Like this:
`{:system, "MONGODB_URL", "mongodb://localhost:27017/cluster_heartbeat"}`

```elixir
config :libcluster,
  topologies: [
    example: [
      strategy: ClusterDB.Strategy.Mongo,
      config: [
        mongodb: [
          url: "mongodb://localhost:27017/cluster_heartbeat",
          type: :unknown,
          pool_handler: DBConnection.Poolboy,
          collection_name: "node_status"
        ],
        heartbeat: [interval: 1000, delay_tolerance: 1000],
      ],
    ]
  ]
```
