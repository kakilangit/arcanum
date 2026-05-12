defmodule Arcanum.Adapters.OpenAI do
  @moduledoc """
  Inference adapter for OpenAI-compatible APIs.

  Handles wire protocol translation:
  - Request serialization (messages, tools, provider routing, multimodal content)
  - System role demotion at serialization time (profile-driven)
  - Response parsing (faithful field mapping)
  - Image generation via `/images/generations`
  - Retry on transient HTTP errors (429, 502, 503, 529)

  Model-specific normalization (content fallback, XML tool-call extraction)
  is handled by `Response.Normalizer` in the Gateway layer.
  """

  @behaviour Arcanum.Provider

  alias Arcanum.{Intent, MediaIntent, MediaResponse, ModelProfile, Response}

  @receive_timeout :timer.minutes(5)
  @max_retry_attempts 3
  @retriable_statuses [429, 502, 503, 529]

  @context_overflow_patterns [
    "context_length_exceeded",
    "maximum context length",
    "token limit",
    "too many tokens",
    "context window",
    "max_tokens",
    "input is too long",
    "request too large"
  ]

  @impl true
  def chat(provider, %Intent{} = intent, %ModelProfile{} = profile) do
    body = build_chat_body(intent, provider, profile)

    case do_request(provider, body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_chat_response(body)}

      {:ok, %{status: status, body: body}} when status in @retriable_statuses ->
        retry_chat(provider, body, 1)

      {:ok, %{status: status, body: body}} ->
        classify_api_error(status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(provider, %Intent{} = intent, %ModelProfile{} = profile) do
    body = build_chat_body(intent, provider, profile) |> Map.put(:stream, true)

    case do_stream_request(provider, body) do
      {:ok, %{status: 200, body: stream}} ->
        {:ok, parse_sse_stream(stream)}

      {:ok, %{status: status}} when status in @retriable_statuses ->
        retry_stream(provider, body, 1)

      {:ok, %{status: status, body: resp_body}} ->
        classify_api_error(status, drain_async_body(resp_body))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_models(provider) do
    case http_client().get(base_url(provider, "/models"), headers: headers(provider)) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        {:ok, extract_model_ids(provider, models)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def embed(provider, model, input) do
    body = %{model: model, input: input}

    case http_client().post(base_url(provider, "/embeddings"),
           json: body,
           headers: headers(provider),
           receive_timeout: @receive_timeout
         ) do
      {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}} ->
        {:ok, embedding}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def generate_image(provider, %MediaIntent{} = intent, %ModelProfile{}) do
    body =
      %{model: intent.model, prompt: intent.prompt, n: intent.n, size: intent.size}
      |> maybe_put(:quality, intent.quality)
      |> maybe_put(:style, intent.style)
      |> maybe_put(:output_format, intent.format)

    case http_client().post(base_url(provider, "/images/generations"),
           json: body,
           headers: headers(provider),
           receive_timeout: @receive_timeout
         ) do
      {:ok, %{status: 200, body: %{"data" => items}}} ->
        {:ok, %MediaResponse{items: parse_image_items(items, intent.format)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def build_chat_body(%Intent{} = intent, _provider, %ModelProfile{} = profile) do
    {messages, tools} = prepare_tools(intent, profile)
    messages = format_messages(messages, profile)

    body = %{model: intent.model, messages: messages}
    body = if tools, do: Map.put(body, :tools, tools), else: body
    body = if intent.temperature, do: Map.put(body, :temperature, intent.temperature), else: body
    body = if intent.max_tokens, do: Map.put(body, :max_tokens, intent.max_tokens), else: body
    body = apply_thinking_param(body, profile)

    apply_provider_routing(body, profile)
  end

  defp prepare_tools(%Intent{tools: nil} = intent, _profile), do: {intent.messages, nil}
  defp prepare_tools(%Intent{tools: []} = intent, _profile), do: {intent.messages, nil}

  defp prepare_tools(%Intent{} = intent, %ModelProfile{supports_tools: true}),
    do: {intent.messages, intent.tools}

  defp prepare_tools(%Intent{tools: tools} = intent, %ModelProfile{supports_tools: false}) do
    tool_schema = Jason.encode!(tools)
    tool_message = %{role: :system, content: Intent.text("Available tools:\n#{tool_schema}")}

    {system, rest} = Enum.split_while(intent.messages, &(Map.get(&1, :role) == :system))
    {system ++ [tool_message] ++ rest, nil}
  end

  defp apply_provider_routing(body, %{provider_routing: nil}), do: body

  defp apply_provider_routing(body, %{provider_routing: routing}) when is_map(routing) do
    if Map.has_key?(body, :tools), do: Map.merge(body, routing), else: body
  end

  defp apply_thinking_param(body, %{thinking_param: nil}), do: body
  defp apply_thinking_param(body, %{thinking_param: param}), do: Map.put(body, :thinking, param)

  defp format_messages(messages, profile) when is_list(messages) do
    messages
    |> apply_reasoning_transforms(profile)
    |> Enum.flat_map(&format_message(&1, profile))
  end

  defp apply_reasoning_transforms(messages, %{
         reasoning_field: :reasoning_content,
         preserve_reasoning: true
       }) do
    Enum.map(messages, fn
      %{role: :assistant} = msg -> Map.put_new(msg, :thinking, "")
      msg -> msg
    end)
  end

  defp apply_reasoning_transforms(messages, %{reasoning_field: :reasoning_content}) do
    last_idx = find_last_assistant_index(messages)

    messages
    |> Enum.with_index()
    |> Enum.map(fn {msg, idx} -> transform_reasoning(msg, idx, last_idx) end)
  end

  defp apply_reasoning_transforms(messages, _profile), do: messages

  defp find_last_assistant_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.filter(fn {msg, _} -> msg[:role] == :assistant end)
    |> List.last()
    |> case do
      {_msg, idx} -> idx
      nil -> -1
    end
  end

  defp transform_reasoning(%{role: :assistant} = msg, idx, idx),
    do: Map.put_new(msg, :thinking, "")

  defp transform_reasoning(%{role: :assistant} = msg, _idx, _last_idx),
    do: Map.put(msg, :thinking, "")

  defp transform_reasoning(msg, _idx, _last_idx), do: msg

  defp format_message(%{role: :system} = msg, %{supports_system_role: false}) do
    [%{role: "user", content: "[System Instructions]\n\n#{Intent.to_text(msg.content)}"}]
  end

  defp format_message(%{role: :tool} = msg, _profile) do
    content = Intent.to_text(msg[:content] || [])

    [
      %{
        role: "tool",
        content: content,
        tool_call_id: to_string(msg[:tool_call_id])
      }
    ]
  end

  defp format_message(%{role: :assistant, tool_calls: tool_calls} = msg, _profile)
       when is_list(tool_calls) and tool_calls != [] do
    content = Intent.to_text(msg[:content] || [])
    has_thinking = is_binary(msg[:thinking]) and msg[:thinking] != ""

    if has_thinking do
      combined =
        %{
          role: "assistant",
          content: content,
          tool_calls: Enum.map(tool_calls, &format_tool_call/1)
        }
        |> add_reasoning_content(msg)

      [combined]
    else
      text_msg =
        if content != "" do
          [%{role: "assistant", content: content}]
        else
          []
        end

      tool_msg = %{role: "assistant", tool_calls: Enum.map(tool_calls, &format_tool_call/1)}
      text_msg ++ [tool_msg]
    end
  end

  defp format_message(%{role: role} = msg, _profile) do
    base = %{role: to_string(role), content: serialize_content(msg[:content] || [])}
    [add_reasoning_content(base, msg)]
  end

  defp add_reasoning_content(formatted, %{thinking: thinking})
       when is_binary(thinking) and thinking != "" do
    Map.put(formatted, "reasoning_content", thinking)
  end

  defp add_reasoning_content(formatted, _msg), do: formatted

  defp format_tool_call(%{id: id, function: func}) do
    %{
      id: to_string(id),
      type: "function",
      function: %{
        name: func.name || func[:name],
        arguments: func.arguments || func[:arguments] || "{}"
      }
    }
  end

  defp format_tool_call(tc), do: tc

  @doc """
  Serializes content blocks to OpenAI wire format.

  Text-only messages are sent as a plain string (single text block optimization).
  Mixed content is sent as an array of typed objects.
  """
  def serialize_content([%{type: :text, text: text}]), do: text

  def serialize_content(blocks) when is_list(blocks) and blocks != [] do
    Enum.map(blocks, fn
      %{type: :text, text: text} ->
        %{"type" => "text", "text" => text}

      %{type: :image_url, url: url} ->
        %{"type" => "image_url", "image_url" => %{"url" => url}}

      %{type: :image_base64, media_type: mt, data: data} ->
        %{"type" => "image_url", "image_url" => %{"url" => "data:#{mt};base64,#{data}"}}
    end)
  end

  def serialize_content([]), do: ""
  def serialize_content(nil), do: ""

  defp parse_chat_response(body) do
    choice = List.first(body["choices"] || []) || %{}
    message = choice["message"] || %{}

    %Response{
      content: non_blank(message["content"]),
      thinking: non_blank(message["reasoning_content"]),
      tool_calls: parse_tool_calls(message["tool_calls"]),
      usage: parse_usage(body["usage"]),
      finish_reason: choice["finish_reason"]
    }
  end

  defp parse_tool_calls(nil), do: nil
  defp parse_tool_calls([]), do: nil

  defp parse_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc["id"],
        function: %{
          name: get_in(tc, ["function", "name"]),
          arguments: get_in(tc, ["function", "arguments"]) || "{}"
        }
      }
    end)
  end

  defp parse_tool_call_deltas(nil), do: nil
  defp parse_tool_call_deltas([]), do: nil

  defp parse_tool_call_deltas(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        index: tc["index"],
        id: tc["id"],
        function: %{
          name: get_in(tc, ["function", "name"]),
          arguments: get_in(tc, ["function", "arguments"]) || ""
        }
      }
    end)
  end

  defp parse_image_items(items, format) do
    content_type = format_to_content_type(format)

    Enum.map(items, fn item ->
      %{
        data: decode_image_data(item),
        url: item["url"],
        revised_prompt: item["revised_prompt"],
        content_type: content_type
      }
    end)
  end

  defp decode_image_data(%{"b64_json" => data}) when is_binary(data), do: Base.decode64!(data)
  defp decode_image_data(_), do: nil

  defp format_to_content_type("png"), do: "image/png"
  defp format_to_content_type("jpeg"), do: "image/jpeg"
  defp format_to_content_type("webp"), do: "image/webp"
  defp format_to_content_type(_), do: "image/png"

  defp retry_chat(_provider, _body, attempt) when attempt >= @max_retry_attempts do
    {:error, {:api_error, :max_retries_exceeded}}
  end

  defp retry_chat(provider, original_body, attempt) do
    backoff(attempt)

    case do_request(provider, original_body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_chat_response(body)}

      {:ok, %{status: status}} when status in @retriable_statuses ->
        retry_chat(provider, original_body, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        classify_api_error(status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_stream(_provider, _body, attempt) when attempt >= @max_retry_attempts do
    {:error, {:api_error, :max_retries_exceeded}}
  end

  defp retry_stream(provider, body, attempt) do
    backoff(attempt)

    case do_stream_request(provider, body) do
      {:ok, %{status: 200, body: stream}} ->
        {:ok, parse_sse_stream(stream)}

      {:ok, %{status: status}} when status in @retriable_statuses ->
        retry_stream(provider, body, attempt + 1)

      {:ok, %{status: status, body: resp_body}} ->
        classify_api_error(status, drain_async_body(resp_body))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backoff(attempt) do
    delay = min(:timer.seconds(2) * Integer.pow(2, attempt - 1), :timer.seconds(30))
    Process.sleep(delay)
  end

  defp parse_sse_stream(stream) do
    Stream.transform(stream, :cont, fn
      chunk, :cont ->
        events = parse_sse_chunk(chunk)

        case Enum.find(events, &match?(:done, &1)) do
          :done -> {events, :done}
          nil -> {events, :cont}
        end

      _chunk, :done ->
        {:halt, :done}
    end)
  end

  defp parse_sse_chunk(chunk) when is_binary(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.flat_map(&parse_sse_line/1)
  end

  defp parse_sse_chunk(%{data: data}), do: parse_sse_chunk(data)
  defp parse_sse_chunk(_), do: []

  defp parse_sse_line("data: [DONE]"), do: [:done]

  defp parse_sse_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, body} -> [{:data, parse_stream_delta(body)}]
      {:error, _} -> []
    end
  end

  defp parse_sse_line(_), do: []

  defp parse_stream_delta(body) do
    choice = List.first(body["choices"] || []) || %{}
    delta = choice["delta"] || %{}

    %Response{
      content: delta["content"],
      thinking: delta["reasoning_content"],
      tool_calls: parse_tool_call_deltas(delta["tool_calls"]),
      usage: parse_usage(body["usage"]),
      finish_reason: choice["finish_reason"]
    }
  end

  defp do_request(provider, body) do
    http_client().post(base_url(provider, "/chat/completions"),
      json: body,
      headers: headers(provider),
      receive_timeout: @receive_timeout
    )
  end

  defp do_stream_request(provider, body) do
    http_client().post(base_url(provider, "/chat/completions"),
      json: body,
      headers: headers(provider),
      into: :self,
      receive_timeout: @receive_timeout
    )
  end

  defp headers(provider) do
    base =
      case Map.get(provider, :api_key) do
        nil -> [{"content-type", "application/json"}]
        "" -> [{"content-type", "application/json"}]
        key -> [{"content-type", "application/json"}, {"authorization", "Bearer #{key}"}]
      end

    case Map.get(provider, :extra_headers) do
      nil -> base
      extras when is_list(extras) -> base ++ extras
    end
  end

  defp base_url(provider, path) do
    provider.base_url
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp http_client do
    Application.get_env(:arcanum, :http_client, Req)
  end

  defp parse_usage(nil), do: nil

  defp parse_usage(usage) do
    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0
    }
  end

  defp non_blank(s) when is_binary(s) and s != "", do: String.trim(s)
  defp non_blank(_), do: nil

  defp classify_api_error(status, body) do
    error_message = extract_error_message(body)

    if context_overflow?(error_message) do
      {:error, :context_overflow}
    else
      {:error, {:api_error, status, body}}
    end
  end

  defp context_overflow?(nil), do: false

  defp context_overflow?(message) do
    downcased = String.downcase(message)
    Enum.any?(@context_overflow_patterns, &String.contains?(downcased, &1))
  end

  defp extract_error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(_), do: nil

  defp drain_async_body(%Req.Response.Async{} = async) do
    raw =
      async
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      _ -> raw
    end
  rescue
    _ -> nil
  end

  defp drain_async_body(body), do: body

  defp extract_model_ids(%{kind: "github-copilot"}, models) do
    models
    |> Enum.reject(fn m -> get_in(m, ["policy", "state"]) == "disabled" end)
    |> Enum.map(& &1["id"])
  end

  defp extract_model_ids(_provider, models) do
    Enum.map(models, & &1["id"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
