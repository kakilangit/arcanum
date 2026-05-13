defmodule Arcanum.Adapters.Ollama do
  @moduledoc """
  Inference adapter for Ollama.

  Handles wire protocol translation:
  - Request serialization (messages, tools, multimodal content via `images` field)
  - System role demotion at serialization time (profile-driven)
  - Response parsing (faithful field mapping)
  - Embeddings via `/api/embed`
  - Retry on transient HTTP errors (429, 502, 503)

  Ollama multimodal works differently from OpenAI/Anthropic: images are passed
  as a separate `images` field (list of base64 strings) on the message, alongside
  the text `content` field. This adapter handles that split automatically from
  canonical content blocks.
  """

  use Arcanum.Provider

  alias Arcanum.{Intent, ModelProfile, Response}

  @receive_timeout :timer.minutes(5)
  @max_retry_attempts 3
  @retriable_statuses [429, 502, 503]

  @doc """
  Sends a synchronous chat completion request.
  """
  @impl true
  def chat(provider, %Intent{} = intent, %ModelProfile{} = profile) do
    body = build_chat_body(intent, profile)

    case do_request(provider, "/api/chat", body) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, parse_chat_response(resp)}

      {:ok, %{status: status}} when status in @retriable_statuses ->
        retry_chat(provider, body, 1)

      {:ok, %{status: status, body: resp}} ->
        {:error, {:api_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a streaming chat completion request. Returns a `Stream` of `{:data, response}` and `:done`.
  """
  @impl true
  def stream(provider, %Intent{} = intent, %ModelProfile{} = profile) do
    body = build_chat_body(intent, profile) |> Map.put(:stream, true)

    case http_client().post(base_url(provider, "/api/chat"),
           json: body,
           into: :self,
           receive_timeout: @receive_timeout
         ) do
      {:ok, %{status: 200, body: stream}} ->
        {:ok, parse_stream(stream)}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:api_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists available models via Ollama's tags endpoint.
  """
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
  Generates embeddings via `/api/embed`.
  """
  @impl true
  def embed(provider, model, input) do
    body = %{model: model, input: input}

    case do_request(provider, "/api/embed", body) do
      {:ok, %{status: 200, body: %{"embeddings" => [embedding | _]}}} ->
        {:ok, embedding}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:api_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_chat_body(%Intent{} = intent, %ModelProfile{} = profile) do
    messages = serialize_messages(intent.messages, profile)

    body = %{
      model: intent.model,
      messages: messages,
      stream: false
    }

    body = maybe_add_tools(body, intent.tools)
    maybe_add_options(body, intent)
  end

  defp serialize_messages(messages, profile) do
    messages
    |> Enum.take(500)
    |> Enum.map(&serialize_message(&1, profile))
    |> maybe_demote_system(profile)
  end

  defp serialize_message(%{role: role, content: content} = msg, _profile) do
    {text, images} = split_content(content)

    base = %{
      "role" => to_string(role),
      "content" => text
    }

    base = if images != [], do: Map.put(base, "images", images), else: base

    case Map.get(msg, :tool_calls) do
      nil -> base
      calls -> Map.put(base, "tool_calls", serialize_tool_calls(calls))
    end
  end

  defp split_content(content) when is_list(content) do
    {texts, images} =
      Enum.reduce(content, {[], []}, fn
        %{type: :text, text: t}, {ts, imgs} ->
          {[t | ts], imgs}

        %{type: :image_base64, data: data}, {ts, imgs} ->
          {ts, [data | imgs]}

        %{type: :image_url}, {ts, imgs} ->
          {ts, imgs}

        _, acc ->
          acc
      end)

    text = texts |> Enum.reverse() |> Enum.join("\n")
    {text, Enum.reverse(images)}
  end

  defp split_content(content) when is_binary(content), do: {content, []}
  defp split_content(_), do: {"", []}

  defp maybe_demote_system(messages, %ModelProfile{supports_system_role: true}), do: messages

  defp maybe_demote_system(messages, _profile) do
    Enum.map(messages, fn
      %{"role" => "system"} = msg -> Map.put(msg, "role", "user")
      msg -> msg
    end)
  end

  defp serialize_tool_calls(calls) do
    Enum.map(calls, fn tc ->
      %{
        "id" => tc.id || generate_tool_call_id(),
        "function" => %{
          "name" => tc.function.name,
          "arguments" => encode_arguments(tc.function.arguments)
        }
      }
    end)
  end

  defp maybe_add_tools(body, nil), do: body
  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)

  defp maybe_add_options(body, %Intent{} = intent) do
    options =
      %{}
      |> maybe_put(:num_ctx, intent.context_length)
      |> maybe_put(:temperature, intent.temperature)

    if options == %{}, do: body, else: Map.put(body, :options, options)
  end

  defp parse_chat_response(body) do
    raw_content = get_in(body, ["message", "content"])

    content =
      case raw_content do
        nil -> nil
        "" -> nil
        s when is_binary(s) -> [%{type: :text, text: s}]
      end

    %Response{
      content: content,
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

  defp do_request(provider, path, body) do
    http_client().post(base_url(provider, path),
      json: body,
      receive_timeout: @receive_timeout
    )
  end

  defp retry_chat(provider, body, attempt) when attempt >= @max_retry_attempts do
    case do_request(provider, "/api/chat", body) do
      {:ok, %{status: 200, body: resp}} -> {:ok, parse_chat_response(resp)}
      {:ok, %{status: status, body: resp}} -> {:error, {:api_error, status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_chat(provider, body, attempt) do
    Process.sleep(backoff_ms(attempt))

    case do_request(provider, "/api/chat", body) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, parse_chat_response(resp)}

      {:ok, %{status: status}} when status in @retriable_statuses ->
        retry_chat(provider, body, attempt + 1)

      {:ok, %{status: status, body: resp}} ->
        {:error, {:api_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backoff_ms(attempt), do: min(:timer.seconds(attempt * 2), :timer.seconds(10))

  defp encode_arguments(args) when is_map(args), do: Jason.encode!(args)
  defp encode_arguments(args) when is_binary(args), do: args
  defp encode_arguments(_), do: "{}"

  defp generate_tool_call_id do
    "call_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp base_url(provider, path) do
    String.trim_trailing(provider.base_url, "/") <> path
  end

  defp http_client do
    Application.get_env(:arcanum, :http_client, Req)
  end
end
