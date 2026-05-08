defmodule Arcanum.EnsureModel do
  @moduledoc """
  Ensures a model is loaded with the correct configuration on local
  providers (LM Studio, Ollama, vLLM) before inference begins.

  LM Studio: checks GET /api/v1/models for loaded_instances first,
             only calls POST /api/v1/models/load when the model
             isn't already loaded with the required context_length.
  Ollama:    POST /api/generate with keep_alive (or model is auto-loaded)

  For cloud providers this is a no-op.
  """

  require Logger

  @load_timeout :timer.seconds(120)

  @doc """
  Ensures the model is loaded on the provider with the configured
  context length. Returns `:ok` or `{:error, reason}`.

  No-op for cloud providers or when context_length is nil.
  """
  def ensure_loaded(provider, model, opts \\ []) do
    case provider.kind do
      kind when kind in ["lmstudio"] ->
        context_length = Keyword.get(opts, :context_length)
        ensure_lmstudio(provider, model, context_length)

      _other ->
        :ok
    end
  end

  defp ensure_lmstudio(provider, model, context_length) do
    if is_nil(context_length) do
      :ok
    else
      case already_loaded?(provider, model, context_length) do
        true ->
          Logger.debug("Model #{model} already loaded with sufficient context_length")
          :ok

        false ->
          load_lmstudio(provider, model, context_length)
      end
    end
  end

  # Checks GET /api/v1/models to see if the model already has a
  # loaded instance with context_length >= the requested value.
  defp already_loaded?(provider, model, required_context_length) do
    url = rest_url(provider, "/api/v1/models")

    case http_client().get(url, headers: [{"content-type", "application/json"}]) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        models
        |> Enum.find(&(&1["key"] == model))
        |> model_has_loaded_instance?(required_context_length)

      _ ->
        false
    end
  end

  defp model_has_loaded_instance?(nil, _required), do: false

  defp model_has_loaded_instance?(model_info, required_context_length) do
    model_info
    |> Map.get("loaded_instances", [])
    |> Enum.any?(&(get_in(&1, ["config", "context_length"]) >= required_context_length))
  end

  defp load_lmstudio(provider, model, context_length) do
    url = rest_url(provider, "/api/v1/models/load")

    body = %{
      model: model,
      context_length: context_length
    }

    Logger.info("Loading model #{model} with context_length=#{context_length}")

    case http_client().post(url,
           json: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: @load_timeout
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("Model load returned #{status}: #{inspect(resp_body)}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to load model: #{inspect(reason)}")
        {:error, {:model_load_failed, reason}}
    end
  end

  defp rest_url(provider, path) do
    provider.base_url
    |> String.trim_trailing("/")
    |> String.trim_trailing("/v1")
    |> Kernel.<>(path)
  end

  defp http_client do
    Application.get_env(:arcanum, :http_client, Req)
  end
end
