defmodule Arcanum.Adapters.Anthropic do
  @moduledoc """
  Inference adapter for the Anthropic Messages API.

  Handles Anthropic-specific wire format:
  - System prompt as top-level parameter (not a message)
  - Content blocks for text, tool_use, tool_result, thinking
  - Tool definitions as `name/description/input_schema` (not OpenAI function format)
  - Roles as strings, only `"user"` and `"assistant"` allowed in messages
  - Tool results sent as `"user"` role with `tool_result` content blocks

  Profile-driven: uses `ModelProfile` for capability checks, same as OpenAI adapter.
  """

  @behaviour Arcanum.Provider

  alias Arcanum.{Intent, ModelProfile, Response}

  @anthropic_version "2023-06-01"
  @receive_timeout :timer.minutes(5)
  @max_retry_attempts 3
  @retriable_statuses [429, 502, 503, 529]

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @impl true
  def chat(provider, %Intent{} = intent, %ModelProfile{} = profile) do
    body = build_chat_body(intent, profile)

    case do_request(provider, body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_chat_response(body)}

      {:ok, %{status: status, body: body}} when status in @retriable_statuses ->
        retry_chat(provider, body, 1)

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(provider, %Intent{} = intent, %ModelProfile{} = profile) do
    body = Map.put(build_chat_body(intent, profile), :stream, true)

    case do_stream_request(provider, body) do
      {:ok, %{status: 200, body: stream}} ->
        {:ok, parse_sse_stream(stream)}

      {:ok, %{status: status, body: body}} when status in @retriable_statuses ->
        retry_stream(provider, body, 1)

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_models(provider) do
    case http_client().get(base_url(provider, "/v1/models"), headers: headers(provider)) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        {:ok, Enum.map(models, & &1["id"])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Request body construction (profile-driven)
  # -------------------------------------------------------------------

  defp build_chat_body(%Intent{} = intent, %ModelProfile{} = profile) do
    {system, messages} = extract_system(intent.messages)
    messages = format_messages(messages, profile)

    body = %{model: intent.model, messages: messages}

    body = if system, do: Map.put(body, :system, system), else: body

    body =
      if intent.tools && intent.tools != [],
        do: Map.put(body, :tools, to_anthropic_tools(intent.tools)),
        else: body

    body =
      if intent.temperature, do: Map.put(body, :temperature, intent.temperature), else: body

    body =
      if intent.max_tokens,
        do: Map.put(body, :max_tokens, intent.max_tokens),
        else: Map.put(body, :max_tokens, 4096)

    body
  end

  # Extract system messages (atom or string role) from the front
  defp extract_system(messages) do
    {system_msgs, rest} = Enum.split_while(messages, &system_role?/1)

    case system_msgs do
      [] ->
        {nil, messages}

      msgs ->
        combined =
          msgs
          |> Enum.map_join("\n\n", &to_string(Map.get(&1, :content, "")))

        {combined, rest}
    end
  end

  defp system_role?(%{role: :system}), do: true
  defp system_role?(%{role: "system"}), do: true
  defp system_role?(_), do: false

  # -------------------------------------------------------------------
  # Message formatting — Anthropic wire format
  #
  # Anthropic only allows "user" and "assistant" roles.
  # Tool results must be "user" role with tool_result content blocks.
  # Assistant tool calls must be content blocks (not tool_calls key).
  # -------------------------------------------------------------------

  defp format_messages(messages, profile) do
    messages
    |> Enum.flat_map(&format_message(&1, profile))
    |> merge_adjacent_roles()
  end

  # System messages that weren't at the front — inject as user message
  defp format_message(%{role: role} = msg, _profile) when role in [:system, "system"] do
    [%{role: "user", content: "[System] #{msg[:content] || ""}"}]
  end

  # Tool result messages → user role with tool_result content blocks
  defp format_message(%{role: role} = msg, _profile) when role in [:tool, "tool"] do
    content = to_string(msg[:content] || "")
    tool_call_id = to_string(msg[:tool_call_id] || "")

    block = %{type: "tool_result", tool_use_id: tool_call_id, content: content}

    [%{role: "user", content: [block]}]
  end

  # Assistant with tool_calls → content blocks (text + tool_use)
  defp format_message(%{role: role, tool_calls: tool_calls} = msg, _profile)
       when role in [:assistant, "assistant"] and is_list(tool_calls) and tool_calls != [] do
    text_blocks = text_content_block(msg[:content])
    tool_blocks = Enum.map(tool_calls, &to_tool_use_block/1)

    [%{role: "assistant", content: text_blocks ++ tool_blocks}]
  end

  # Plain assistant message
  defp format_message(%{role: role} = msg, _profile) when role in [:assistant, "assistant"] do
    [%{role: "assistant", content: to_string(msg[:content] || "")}]
  end

  # User message
  defp format_message(%{role: role} = msg, _profile) when role in [:user, "user"] do
    [%{role: "user", content: to_string(msg[:content] || "")}]
  end

  # Fallback — treat as user
  defp format_message(msg, _profile) do
    [%{role: "user", content: to_string(msg[:content] || "")}]
  end

  defp text_content_block(text) when is_binary(text) and text != "" do
    [%{type: "text", text: text}]
  end

  defp text_content_block(_), do: []

  defp to_tool_use_block(call) do
    func = call[:function] || call.function
    raw_args = func[:arguments] || func.arguments

    %{
      type: "tool_use",
      id: to_string(call[:id] || call.id),
      name: to_string(func[:name] || func.name),
      input: decode_arguments(raw_args)
    }
  end

  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp decode_arguments(args) when is_map(args), do: args
  defp decode_arguments(_), do: %{}

  # Anthropic requires alternating user/assistant roles.
  # Merge adjacent messages with the same role into one.
  defp merge_adjacent_roles([]), do: []

  defp merge_adjacent_roles(messages) do
    messages
    |> Enum.chunk_by(& &1.role)
    |> Enum.map(&merge_chunk/1)
  end

  defp merge_chunk([single]), do: single

  defp merge_chunk([%{role: role} | _] = chunk) do
    merged_content =
      Enum.flat_map(chunk, fn msg ->
        case msg.content do
          blocks when is_list(blocks) -> blocks
          text when is_binary(text) -> [%{type: "text", text: text}]
        end
      end)

    %{role: role, content: merged_content}
  end

  # -------------------------------------------------------------------
  # Tool format conversion (OpenAI → Anthropic)
  # -------------------------------------------------------------------

  defp to_anthropic_tools(tools) do
    Enum.map(tools, fn tool ->
      func = tool[:function] || tool.function

      %{
        name: func[:name] || func.name,
        description: func[:description] || func.description,
        input_schema: func[:parameters] || func.parameters
      }
    end)
  end

  # -------------------------------------------------------------------
  # Response parsing
  # -------------------------------------------------------------------

  defp parse_chat_response(body) do
    %Response{
      content: extract_text_content(body["content"]),
      thinking: extract_thinking_content(body["content"]),
      tool_calls: extract_tool_calls(body["content"]),
      usage: parse_usage(body["usage"]),
      finish_reason: map_stop_reason(body["stop_reason"])
    }
  end

  defp extract_text_content(nil), do: nil

  defp extract_text_content(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_thinking_content(nil), do: nil

  defp extract_thinking_content(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "thinking"))
    |> Enum.map_join("", & &1["thinking"])
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_tool_calls(nil), do: nil

  defp extract_tool_calls(blocks) do
    tool_uses = Enum.filter(blocks, &(&1["type"] == "tool_use"))

    case tool_uses do
      [] ->
        nil

      uses ->
        Enum.map(uses, fn tu ->
          %{
            id: tu["id"],
            function: %{
              name: tu["name"],
              arguments: Jason.encode!(tu["input"] || %{})
            }
          }
        end)
    end
  end

  defp parse_usage(nil), do: nil

  defp parse_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    %{
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens: input + output
    }
  end

  defp map_stop_reason("end_turn"), do: "stop"
  defp map_stop_reason("tool_use"), do: "tool_calls"
  defp map_stop_reason("max_tokens"), do: "length"
  defp map_stop_reason(other), do: other

  # -------------------------------------------------------------------
  # Retry middleware (bounded)
  # -------------------------------------------------------------------

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
        {:error, {:api_error, status, body}}

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
        {:error, {:api_error, status, drain_async_body(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backoff(attempt) do
    delay = min(:timer.seconds(2) * Integer.pow(2, attempt - 1), :timer.seconds(30))
    Process.sleep(delay)
  end

  # -------------------------------------------------------------------
  # SSE stream parsing
  # -------------------------------------------------------------------

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

  defp parse_sse_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, event} -> [process_sse_event(event)]
      {:error, _} -> []
    end
  end

  defp parse_sse_line(_), do: []

  defp process_sse_event(%{
         "type" => "content_block_delta",
         "delta" => %{"type" => "text_delta", "text" => text}
       }) do
    {:data, %Response{content: text}}
  end

  defp process_sse_event(%{
         "type" => "content_block_delta",
         "delta" => %{"type" => "thinking_delta", "thinking" => thinking}
       }) do
    {:data, %Response{thinking: thinking}}
  end

  defp process_sse_event(%{
         "type" => "content_block_delta",
         "delta" => %{"type" => "input_json_delta", "partial_json" => json},
         "index" => index
       }) do
    {:data,
     %Response{
       tool_calls: [
         %{index: index, function: %{arguments: json}}
       ]
     }}
  end

  defp process_sse_event(%{
         "type" => "content_block_start",
         "content_block" => %{"type" => "tool_use", "id" => id, "name" => name},
         "index" => index
       }) do
    {:data,
     %Response{
       tool_calls: [
         %{index: index, id: id, function: %{name: name, arguments: ""}}
       ]
     }}
  end

  defp process_sse_event(%{"type" => "message_stop"}) do
    :done
  end

  defp process_sse_event(%{"type" => "message_delta"} = event) do
    usage = parse_usage(event["usage"])

    {:data,
     %Response{
       usage: usage,
       finish_reason: map_stop_reason(get_in(event, ["delta", "stop_reason"]))
     }}
  end

  defp process_sse_event(_event), do: {:data, %Response{}}

  # -------------------------------------------------------------------
  # HTTP helpers
  # -------------------------------------------------------------------

  defp do_request(provider, body) do
    http_client().post(base_url(provider, "/v1/messages"),
      json: body,
      headers: headers(provider),
      receive_timeout: @receive_timeout
    )
  end

  defp do_stream_request(provider, body) do
    http_client().post(base_url(provider, "/v1/messages"),
      json: body,
      headers: headers(provider),
      into: :self,
      receive_timeout: @receive_timeout
    )
  end

  defp headers(provider) do
    base = [
      {"content-type", "application/json"},
      {"anthropic-version", @anthropic_version}
    ]

    case Map.get(provider, :api_key) do
      nil -> base
      "" -> base
      key -> [{"x-api-key", key} | base]
    end
  end

  defp base_url(provider, path) do
    provider.base_url
    |> String.trim_trailing("/")
    |> String.trim_trailing("/v1")
    |> Kernel.<>(path)
  end

  defp http_client do
    Application.get_env(:arcanum, :http_client, Req)
  end

  # When `into: :self` is used and the response is non-200, the body is a
  # Req.Response.Async struct. Drain it in-process and attempt JSON decode.
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
end
