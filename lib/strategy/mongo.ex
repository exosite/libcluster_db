defmodule ClusterDB.Strategy.Mongo do

  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy.State

  @pool_name :node_status

  def start_link(opts) do
    Application.ensure_all_started(:mongodb)
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    :erlang.process_flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)
    mongodb = Keyword.get(config, :mongodb)
    mongodb_url = get_setting(mongodb, :url)
    mongodb_type = case get_setting(mongodb, :type) do
      type when is_binary(type) -> String.to_atom(type)
      type -> type
    end
    mongodb_collection_name = get_setting(mongodb, :collection_name)
    service_name = get_setting(config, :service_name)
    heartbeat = Keyword.get(config, :heartbeat)
    interval = get_setting(heartbeat, :interval)
    delay_tolerance = get_setting(heartbeat, :delay_tolerance)
    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      list_nodes: Keyword.fetch!(opts, :list_nodes),
      config: config,
      meta: %{
        hearbeatinterval: interval,
        last_timestamp: timestamp(),
        max_heartbeat_age: (interval + delay_tolerance) * 1000,
        nodes_scan_job: nil,
        node_id: node(),
        collection_name: mongodb_collection_name,
        service_name: service_name,
        last_nodes: MapSet.new([])
      }
    }
    {:ok, _} = :timer.send_after(interval, :heartbeat)
    {:ok, _pid} = Keyword.put([], :type, mongodb_type)
    |> Keyword.put(:name, @pool_name)
    |> Keyword.put(:url, mongodb_url)
    |> Mongo.start_link()

    {:ok, state}
  end

  defp get_setting(keyword_list, key) do
    case Keyword.get(keyword_list, key) do
      {:system, env, default_env} ->
        case System.get_env(env) do
          nil ->
            default_env
          result ->
            result
        end
      result ->
        result
    end
  end

  def handle_info(
    :heartbeat,
    %State{
      meta: %{
        hearbeatinterval: interval,
        last_timestamp: last_timestamp,
        max_heartbeat_age: max_heartbeat_age,
        nodes_scan_job: nodes_scan_job,
        node_id: node_id,
        collection_name: collection_name,
        service_name: service_name
      } = meta
    } = state
  ) do
    case timestamp() do
      timestamp when timestamp < last_timestamp + max_heartbeat_age ->
        {:ok, _} = :timer.send_after(interval, :heartbeat)
        case Mongo.update_one(
          @pool_name,
          collection_name,
          %{"node_id" => node_id, "service_name" => service_name},
          %{"$set" => %{"timestamp" => timestamp}},
          [upsert: true]
        ) do
          {:ok, _update_result} ->
            case nodes_scan_job do
              nil ->
                {
                  :noreply,
                  %{state | meta:
                    %{meta | last_timestamp: timestamp,
                    nodes_scan_job: spawn_monitor(fn() -> :erlang.exit(
                      scan_nodes(timestamp, max_heartbeat_age, meta)
                    ) end)}
                  }
                }
              _ ->
                {
                  :noreply,
                  %{state | meta: %{meta | last_timestamp: timestamp} }
                }
            end
          {:error, _error} ->
            Cluster.Logger.error(" Heartbeat failure", "")
            {:noreply, state}
        end
      timestamp ->
        Cluster.Logger.error(" Heartbeat lagging by #{div((timestamp - last_timestamp), 1000000)}s", "")
        {:noreply, state}
    end
  end

  def handle_info(
    {:DOWN, ref, :process, pid, scan_result},
    %{meta: %{nodes_scan_job: {pid, ref}}} = state
  ) do
    case scan_result do
      {:ok, good_nodes_map} ->
        {:noreply, load(good_nodes_map, state)}
      error ->
        Cluster.Logger.error(" Nodes scan job failed: #{inspect error}", "")
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Cluster.Logger.warn("msg: #{inspect msg}, state: #{inspect state}", "Unknown msg")
    {:noreply, state}
  end

  defp scan_nodes(
    timestamp,
    max_heartbeat_age,
    %{
      collection_name: collection_name,
      service_name: service_name
    } = meta
  ) do
    {good_nodes_map, bad_nodes_map} = Mongo.find(
      @pool_name,
      collection_name,
      %{"service_name" => service_name},
      [projection: %{"_id" => 0}]
    )
    |> Enum.to_list()
    |> Enum.reduce(
      {MapSet.new(), MapSet.new()},
      fn
        (
          %{"node_id" => node_id, "timestamp" => node_timestamp},
          {good_acc, bad_acc}
        ) when node_timestamp < (timestamp - max_heartbeat_age) ->
          {good_acc, MapSet.put(bad_acc, node_id)}
        (%{"node_id" => node_id}, {good_acc, bad_acc}) ->
          {MapSet.put(good_acc, String.to_atom(node_id)), bad_acc}
      end
    )
    case remove_dead_node(MapSet.to_list(bad_nodes_map), meta) do
      :ok ->
        {:ok, good_nodes_map}
      :error ->
        :error
    end
  end

  defp remove_dead_node(
    dead_nodes,
    %{
      collection_name: collection_name,
      service_name: service_name
    }
  ) do
    case Mongo.delete_many(
      @pool_name,
      collection_name,
      %{"node_id" => %{"$in" => dead_nodes}, "service_name" => service_name},
      []
    ) do
      {:ok, _} ->
        :ok
      {:error, error} ->
        Cluster.Logger.error(" remove_dead_nodes error: #{inspect error}", "")
        :error
    end
  end

  defp timestamp() do
    :erlang.system_time(:microsecond)
  end

  defp load(
    good_nodes_map,
    %State{
      topology: topology,
      connect: connect,
      disconnect: disconnect,
      list_nodes: list_nodes,
      meta: %{last_nodes: last_nodes_map} = meta
    } = state
  ) do
    new_nodelist = good_nodes_map
    added = MapSet.difference(good_nodes_map, last_nodes_map)
    removed = MapSet.difference(last_nodes_map, good_nodes_map)

    new_nodelist =
      case Cluster.Strategy.disconnect_nodes(
        topology,
        disconnect,
        list_nodes,
        MapSet.to_list(removed)
      ) do
        :ok ->
          new_nodelist
        {:error, bad_nodes} ->
          # Add back the nodes which should have been removed, but which couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.put(acc, n)
          end)
      end

    new_nodelist =
      case Cluster.Strategy.connect_nodes(topology, connect, list_nodes, MapSet.to_list(added)) do
        :ok ->
          new_nodelist
        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end

    %{state | meta: %{meta | last_nodes: new_nodelist, nodes_scan_job: nil}}
  end

end
