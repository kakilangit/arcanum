defmodule Arcanum.ModelProfile.Registry do
  @moduledoc """
  Fetches and caches model capabilities from models.dev.

  Stores data in ETS for fast concurrent reads. Refreshes hourly.
  Falls back gracefully — if fetch fails, the Resolver uses hardcoded defaults.

  ## Providers

  Only fetches and caches profiles for configured providers (default:
  `["zai", "zhipuai", "deepseek", "openrouter"]`).
  """

  use GenServer

  require Logger

  @table :model_profile_registry
  @refresh_interval :timer.hours(1)
  @fetch_timeout 15_000
  @models_dev_url "https://models.dev/api.json"
  @default_providers ["zai", "zhipuai", "deepseek", "openrouter"]
  @max_models_per_provider 500

  alias Arcanum.ModelProfile

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Looks up a model profile from the registry cache.

  Returns `nil` if the model is not cached (caller should fall back to hardcoded).
  """
  @spec lookup(String.t(), String.t()) :: ModelProfile.t() | nil
  def lookup(provider_kind, model) do
    case :ets.lookup(@table, {provider_kind, model}) do
      [{_key, profile}] -> profile
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns all cached provider IDs.
  """
  @spec cached_providers :: [String.t()]
  def cached_providers do
    case :ets.lookup(@table, :providers) do
      [{:providers, providers}] -> providers
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  # -------------------------------------------------------------------
  # GenServer
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    providers = Keyword.get(opts, :providers, @default_providers)
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    # Fetch asynchronously on startup (don't block app boot)
    send(self(), :refresh)

    {:ok, %{table: table, providers: providers}}
  end

  @impl true
  def handle_info(:refresh, state) do
    case fetch_and_cache(state.providers) do
      {:ok, count} ->
        Logger.info("ModelProfile.Registry: cached #{count} model profiles")

      {:error, reason} ->
        Logger.warning("ModelProfile.Registry: fetch failed: #{inspect(reason)}")
    end

    schedule_refresh()
    {:noreply, state}
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp fetch_and_cache(providers) do
    http_client = Application.get_env(:arcanum, :http_client, Req)

    case http_client.get(@models_dev_url, receive_timeout: @fetch_timeout) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        count = parse_and_store(body, providers)
        {:ok, count}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_and_store(data, providers) do
    # Store which providers we have data for
    available = Enum.filter(providers, &Map.has_key?(data, &1))
    :ets.insert(@table, {:providers, available})

    providers
    |> Enum.map(&store_provider_models(data, &1))
    |> Enum.sum()
  end

  defp store_provider_models(data, provider_id) do
    case Map.get(data, provider_id) do
      %{"models" => models} when is_map(models) ->
        models
        |> Enum.take(@max_models_per_provider)
        |> Enum.each(fn {model_id, model_data} ->
          profile = build_profile(model_data)
          :ets.insert(@table, {{provider_id, model_id}, profile})
        end)

        min(map_size(models), @max_models_per_provider)

      _ ->
        0
    end
  end

  defp build_profile(model_data) do
    %ModelProfile{
      supports_system_role: true,
      supports_tools: model_data["tool_call"] == true,
      tool_call_format: if(model_data["tool_call"] == true, do: :native, else: :xml_text),
      reasoning_field: extract_reasoning_field(model_data),
      max_context: extract_context_limit(model_data)
    }
  end

  defp extract_reasoning_field(%{"interleaved" => %{"field" => field}})
       when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> :reasoning_content
  end

  defp extract_reasoning_field(%{"reasoning" => true}), do: :reasoning_content
  defp extract_reasoning_field(_), do: nil

  defp extract_context_limit(%{"limit" => %{"context" => ctx}}) when is_integer(ctx), do: ctx
  defp extract_context_limit(_), do: 131_072
end
