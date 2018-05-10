defmodule ClusterDB.Strategy.Mongo do

  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy.State

  @pool_name :node_status

  def start_link(opts) do
    Application.ensure_all_started(:mongodb)
    Application.ensure_all_started(:poolboy)
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
    pool_handler = Keyword.get(mongodb, :pool_handler)
    heartbeat = Keyword.get(config, :heartbeat)
    interval = Keyword.get(heartbeat, :interval)
    delay_tolerance = Keyword.get(heartbeat, :delay_tolerance)
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
        pool_handler: pool_handler,
        last_nodes: MapSet.new([])
      }
    }
    {:ok, _} = :timer.send_after(interval, :heartbeat)
    {:ok, _pid} = Keyword.put([], :type, mongodb_type)
    |> Keyword.put(:name, @pool_name)
    |> Keyword.put(:pool, Keyword.get(mongodb, :pool_handler))
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
        pool_handler: pool_handler
      } = meta
    } = state
  ) do
    case timestamp() do
      timestamp when timestamp < last_timestamp + max_heartbeat_age ->
        {:ok, _} = :timer.send_after(interval, :heartbeat)
        case Mongo.update_many(
          @pool_name,
          collection_name,
          %{"node_id" => node_id},
          %{
            "$set" => %{"timestamp" => timestamp},
            "$setOnInsert" => %{"claimer_id" => nil}
          },
          [pool: pool_handler, upsert: true]
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
            Cluster.Logger.error(" Heartbeat failure, shutting down...", "")
            :init.stop()
            {:noreply, state}
        end
      timestamp ->
        Cluster.Logger.error(" Heartbeat lagging by #{div((timestamp - last_timestamp), 1000000)}s, shutting down...", "")
        :init.stop()
        {:noreply, state}
    end
  end

  def handle_info(
    {:DOWN, ref, :process, pid, scan_result},
    %{meta: %{nodes_scan_job: {pid, ref}} = meta} = state
  ) do
    with {:ok, good_nodes_map} <- scan_result,
         {:ok, _} <- unclaim_dead_node(meta)
    do
      {:noreply, load(good_nodes_map, state)}
    else
      error ->
        Cluster.Logger.error(" Nodes scan job failed: #{inspect error}", "")
        :init.stop()
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
      node_id: node_id,
      collection_name: collection_name,
      pool_handler: pool_handler
    } = meta
  ) do
    {good_nodes_map, bad_nodes_map} = Mongo.find(
      @pool_name,
      collection_name,
      %{},
      [pool: pool_handler, projection: %{"_id" => 0}]
    )
    |> Enum.to_list()
    |> Enum.reduce(
      {MapSet.new(), MapSet.new()},
      fn
        (
          %{"node_id" => node_id, "claimer_id" => claimer_id, "timestamp" => node_timestamp},
          {good_acc, bad_acc}
        ) when node_timestamp < (timestamp - max_heartbeat_age) ->
          {good_acc, MapSet.put(bad_acc, {node_id, claimer_id})}
        (%{"node_id" => node_id}, {good_acc, bad_acc}) ->
          {MapSet.put(good_acc, String.to_atom(node_id)), bad_acc}
      end
    )
    dead_nodes = MapSet.to_list(bad_nodes_map)
    with {:ok, dead_node_id} <- claim_dead_node(dead_nodes, dead_nodes, node_id, meta),
         :ok <- remove_dead_node(dead_node_id, meta)
    do
      {:ok, good_nodes_map}
    else
      :notfound ->
        {:ok, good_nodes_map}
      :error ->
        :error
    end
  end

  defp claim_dead_node(dead_nodes, [{dead_node_id, claimer_id} | nodes], node_id, meta) do
    case is_claimer_dead(claimer_id, dead_nodes) do
      false ->
        claim_dead_node(dead_nodes, nodes, node_id, meta)
      true ->
        case do_claim_dead_node(dead_node_id, claimer_id, node_id, meta) do
          {:ok, _} ->
            {:ok, dead_node_id}
          {:error, _} ->
            claim_dead_node(dead_nodes, nodes, node_id, meta)
        end
    end
  end
  defp claim_dead_node(_dead_nodes, [], _node_id, _meta), do: :notfound

  defp is_claimer_dead(nil, _DeadNodes), do: true
  defp is_claimer_dead(node_id, dead_nodes) do
    List.keyfind(dead_nodes, node_id, 0) != nil
  end

  defp do_claim_dead_node(
    dead_node_id,
    claimer_id,
    node_id,
    %{
      collection_name: collection_name,
      pool_handler: pool_handler
    }
  ) do
    Mongo.update_many(
      @pool_name,
      collection_name,
      %{"node_id" => dead_node_id, "claimer_id" => claimer_id},
      %{"$set" => %{"claimer_id" => node_id}},
      [pool: pool_handler]
    )
  end

  defp remove_dead_node(
    dead_node_id,
    %{
      collection_name: collection_name,
      pool_handler: pool_handler
    }
  ) do
    :ok = case Mongo.delete_many(
      @pool_name,
      collection_name,
      %{"node_id" => dead_node_id},
      [pool: pool_handler]
    ) do
      {:ok, _} ->
        :ok
      {:error, error} ->
        Cluster.Logger.error(" remove_dead_node error: #{inspect error}", "")
        :error
    end
  end

  defp unclaim_dead_node(
    %{
      node_id: node_id,
      collection_name: collection_name,
      pool_handler: pool_handler
    }
  ) do
    Mongo.update_many(
      @pool_name,
      collection_name,
      %{"claimer_id" => node_id},
      %{"$set" => %{"claimer_id" => nil}},
      [pool: pool_handler]
    )
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
    new_nodelist = MapSet.to_list(good_nodes_map)
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

    %{state | meta: %{meta | last_nodes: MapSet.new(new_nodelist), nodes_scan_job: nil}}
  end

end
