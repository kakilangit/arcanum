defmodule Arcanum.Adapters.Grimoire do
  @moduledoc """
  Inference adapter for Grimoire plugin providers.

  Grimoire plugins expose a simple HTTP contract:
  - `GET /models` → list available models
  - `POST /chat` → chat completion (streaming via SSE when `stream: true`)

  The provider's `base_url` must point to the plugin container's HTTP root
  (e.g. `http://172.17.0.2:8080`). Context is passed in the request body.

  Unlike OpenAI/Anthropic, messages use a simplified format matching the
  plugin contract spec (role as string, content as string or null).
  """

  use Arcanum.Provider

  alias Arcanum.{HTTP, Intent, ModelProfile, Response, SSE}
  require Logger

  @receive_timeout :timer.minutes(2)
  @done_sentinel "[DONE]"

  @impl true
  def chat(provider, %Intent{} = intent, %ModelProfile{} = _profile) do
    body = build_chat_body(provider, intent, stream: false)
    url = HTTP.base_url(provider, "/chat")

    case HTTP.client().post(url, json: body, receive_timeout: @receive_timeout) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, parse_chat_response(resp_body)}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:grimoire_error, status, inspect(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(provider, %Intent{} = intent, %ModelProfile{} = _profile) do
    body = build_chat_body(provider, intent, stream: true)
    url = HTTP.base_url(provider, "/chat")

    case HTTP.client().post(url,
           json: body,
           receive_timeout: @receive_timeout,
           into: :self
         ) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, parse_sse_stream(resp.body)}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:grimoire_error, status, HTTP.drain_async_body(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_models(provider) do
    url = HTTP.base_url(provider, "/models")
    headers = context_headers(provider)

    case HTTP.client().get(url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        {:ok, Enum.map(models, & &1["id"])}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:grimoire_error, status, inspect(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp build_chat_body(provider, %Intent{} = intent, opts) do
    %{
      context: build_context(provider),
      model: intent.model,
      messages: serialize_messages(intent.messages || []),
      stream: Keyword.get(opts, :stream, false)
    }
    |> maybe_put(:tools, serialize_tools(intent.tools))
    |> maybe_put(:temperature, intent.temperature)
    |> maybe_put(:max_tokens, intent.max_tokens)
  end

  defp serialize_messages(messages) do
    Enum.map(messages, fn msg ->
      base = %{role: to_string(msg.role), content: content_to_string(msg.content)}

      base =
        case Map.get(msg, :tool_calls) do
          nil -> base
          calls -> Map.put(base, :tool_calls, calls)
        end

      case Map.get(msg, :tool_call_id) do
        nil -> base
        id -> Map.put(base, :tool_call_id, id)
      end
    end)
  end

  defp content_to_string(nil), do: nil
  defp content_to_string(content) when is_binary(content), do: content

  defp content_to_string(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("\n", & &1.text)
  end

  defp serialize_tools(nil), do: nil
  defp serialize_tools([]), do: nil
  defp serialize_tools(tools), do: tools

  defp build_context(provider) do
    Map.get(provider, :grimoire_context, %{})
  end

  defp context_headers(provider) do
    context = build_context(provider)

    case Jason.encode(context) do
      {:ok, json} -> [{"x-plugin-context", Base.encode64(json)}]
      _ -> []
    end
  end

  defp parse_chat_response(%{"message" => msg, "finish_reason" => reason} = resp) do
    %Response{
      content: parse_content(msg["content"]),
      tool_calls: parse_tool_calls(msg["tool_calls"]),
      usage: parse_usage(resp["usage"]),
      finish_reason: reason
    }
  end

  defp parse_chat_response(other) do
    Logger.warning("Grimoire: unexpected chat response: #{inspect(other)}")
    %Response{content: nil, finish_reason: "error"}
  end

  defp parse_content(nil), do: nil
  defp parse_content(text) when is_binary(text), do: [%{type: :text, text: text}]

  defp parse_tool_calls(nil), do: nil
  defp parse_tool_calls([]), do: nil

  defp parse_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn tc ->
      %{
        id: tc["id"],
        function: %{
          name: tc["function"]["name"],
          arguments: tc["function"]["arguments"]
        }
      }
    end)
  end

  defp parse_usage(nil), do: nil

  defp parse_usage(u) do
    %{
      prompt_tokens: u["prompt_tokens"] || 0,
      completion_tokens: u["completion_tokens"] || 0,
      total_tokens: u["total_tokens"] || 0
    }
  end

  defp parse_sse_stream(async_body) do
    SSE.stream(async_body, parse_event: &parse_chunk/1, done_sentinel: @done_sentinel)
  end

  defp parse_chunk(%{"delta" => delta} = chunk) do
    response = %Response{
      content: parse_content(delta["content"]),
      tool_calls: parse_tool_call_deltas(delta["tool_calls"]),
      usage: parse_usage(chunk["usage"]),
      finish_reason: chunk["finish_reason"]
    }

    {:data, response}
  end

  defp parse_chunk(_other), do: nil

  defp parse_tool_call_deltas(nil), do: nil
  defp parse_tool_call_deltas([]), do: nil

  defp parse_tool_call_deltas(deltas) do
    Enum.map(deltas, fn d ->
      %{
        index: d["index"],
        id: d["id"],
        function: %{
          name: d["function"]["name"],
          arguments: d["function"]["arguments"] || ""
        }
      }
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
