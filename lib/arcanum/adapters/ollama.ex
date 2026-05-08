defmodule Arcanum.Adapters.Ollama do
  @moduledoc """
  Inference adapter for Ollama.

  Uses the native Ollama API (`/api/chat`, `/api/tags`).
  """

  @behaviour Arcanum.Provider

  alias Arcanum.{Intent, ModelProfile, Response}

  # LLM inference can take a while, especially on local hardware
  @receive_timeout :timer.minutes(5)

  @impl true
  def chat(provider, %Intent{} = intent, %ModelProfile{} = _profile) do
    body = build_chat_body(provider, intent)

    case http_client().post(base_url(provider, "/api/chat"),
           json: body,
           receive_timeout: @receive_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_chat_response(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(provider, %Intent{} = intent, %ModelProfile{} = _profile) do
    body = build_chat_body(provider, intent, stream: true)

    case http_client().post(base_url(provider, "/api/chat"),
           json: body,
           into: :self,
           receive_timeout: @receive_timeout
         ) do
      {:ok, %{status: 200, body: stream}} ->
        {:ok, parse_stream(stream)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_models(provider) do
    case http_client().get(base_url(provider, "/api/tags"), []) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        {:ok, Enum.map(models, & &1["name"])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates embeddings via the Ollama embeddings API.
  """
  @impl true
  def embed(provider, model, input) do
    body = %{model: model, input: input}

    case http_client().post(base_url(provider, "/api/embed"),
           json: body,
           receive_timeout: @receive_timeout
         ) do
      {:ok, %{status: 200, body: %{"embeddings" => [embedding | _]}}} ->
        {:ok, embedding}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_chat_body(_provider, %Intent{} = intent, opts \\ []) do
    body = %{
      model: intent.model,
      messages: intent.messages,
      stream: Keyword.get(opts, :stream, false)
    }

    body =
      if intent.tools do
        Map.put(body, :tools, intent.tools)
      else
        body
      end

    # Build Ollama options: context_length (num_ctx) and temperature
    options =
      %{}
      |> maybe_put(:num_ctx, intent.context_length)
      |> maybe_put(:temperature, intent.temperature)

    if options == %{}, do: body, else: Map.put(body, :options, options)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_chat_response(body) do
    %Response{
      content: get_in(body, ["message", "content"]),
      tool_calls: parse_tool_calls(get_in(body, ["message", "tool_calls"])),
      usage: parse_usage(body),
      finish_reason: body["done_reason"]
    }
  end

  defp parse_tool_calls(nil), do: nil
  defp parse_tool_calls([]), do: nil

  defp parse_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc["id"] || generate_tool_call_id(),
        function: %{
          name: get_in(tc, ["function", "name"]),
          arguments: encode_arguments(get_in(tc, ["function", "arguments"]))
        }
      }
    end)
  end

  defp encode_arguments(args) when is_map(args), do: Jason.encode!(args)
  defp encode_arguments(args) when is_binary(args), do: args
  defp encode_arguments(_), do: "{}"

  defp generate_tool_call_id do
    "call_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp parse_usage(body) do
    case {body["prompt_eval_count"], body["eval_count"]} do
      {nil, nil} ->
        nil

      {prompt, completion} ->
        prompt = prompt || 0
        completion = completion || 0
        %{prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion}
    end
  end

  defp parse_stream(stream) do
    Stream.transform(stream, :cont, fn
      chunk, :cont ->
        case parse_stream_chunk(chunk) do
          {:done, response} -> {[{:data, response}, :done], :done}
          {:data, response} -> {[{:data, response}], :cont}
          :skip -> {[], :cont}
        end

      _chunk, :done ->
        {:halt, :done}
    end)
  end

  defp parse_stream_chunk(chunk) when is_binary(chunk) do
    case Jason.decode(chunk) do
      {:ok, %{"done" => true} = body} -> {:done, parse_chat_response(body)}
      {:ok, body} -> {:data, parse_chat_response(body)}
      {:error, _} -> :skip
    end
  end

  defp parse_stream_chunk(%{data: data}), do: parse_stream_chunk(data)
  defp parse_stream_chunk(_), do: :skip

  defp base_url(provider, path) do
    String.trim_trailing(provider.base_url, "/") <> path
  end

  defp http_client do
    Application.get_env(:arcanum, :http_client, Req)
  end
end
