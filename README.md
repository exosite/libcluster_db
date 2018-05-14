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
  [{:libcluster_db, git: "git@github.com:exosite/libcluster_db.git", branch: "master"}]
end
```

## Deployment

Because it is private, openshift requires credentials to access this repo.

#### 1. Openshift Build configuration:

Add the following credentials to the service build configuration.

```yaml
...
spec:
  ...
  source:
    type: Git
    ...
    secrets:
      -
        secret:
          name: secret-murano-service
```

#### 2. Update your service `dockerfile`

Set the key in the docker image

```dockerfile
# 1. Install ssh package
RUN apt-get update && apt-get -y install openssh-client

# 2. Copy openshift certificate to default folder
RUN mkdir --parent /root/.ssh
COPY murano-service-ssh-key /root/.ssh/id_rsa
RUN chmod og-rwx /root/.ssh/id_rsa
RUN echo "	StrictHostKeyChecking no" >> /etc/ssh/ssh_config
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
