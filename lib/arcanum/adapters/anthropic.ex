defmodule Arcanum.Adapters.Anthropic do
  @moduledoc """
  Inference adapter for the Anthropic Messages API.

  Handles Anthropic-specific wire format:
  - System prompt as top-level parameter (not a message)
  - Content blocks for text, tool_use, tool_result, thinking
  - Tool definitions as `name/description/input_schema`
  - Only `"user"` and `"assistant"` roles allowed in messages
  - Tool results sent as `"user"` role with `tool_result` content blocks
  - Multimodal content blocks (text + images)
  """

  use Arcanum.Provider

  alias Arcanum.{HTTP, Intent, ModelProfile, Response, Retry, SSE}

  @anthropic_version "2023-06-01"
  @receive_timeout :timer.minutes(5)
  @retriable_statuses [429, 502, 503, 529]

  @impl true
  def chat(provider, %Intent{} = intent, %ModelProfile{} = profile) do
    body = build_chat_body(intent, profile)

    Retry.with_retry(
      [
        retriable_statuses: @retriable_statuses,
        on_success: fn %{body: resp_body} -> {:ok, parse_chat_response(resp_body)} end,
        on_error: fn status, resp_body -> {:error, {:api_error, status, resp_body}} end
      ],
      fn -> do_request(provider, body) end
    )
  end

  @impl true
  def stream(provider, %Intent{} = intent, %ModelProfile{} = profile) do
    body = Map.put(build_chat_body(intent, profile), :stream, true)

    Retry.with_retry(
      [
        retriable_statuses: @retriable_statuses,
        on_success: fn %{body: stream} -> {:ok, parse_sse_stream(stream)} end,
        on_error: fn status, resp_body -> {:error, {:api_error, status, resp_body}} end
      ],
      fn -> do_stream_request(provider, body) end
    )
  end

  @impl true
  def list_models(provider) do
    case HTTP.client().get(HTTP.base_url_strip_v1(provider, "/v1/models"),
           headers: headers(provider)
         ) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        {:ok, Enum.map(models, & &1["id"])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_chat_body(%Intent{} = intent, %ModelProfile{} = profile) do
    {system, messages} = extract_system(intent.messages)
    messages = format_messages(messages, profile)

    body = %{model: intent.model, messages: messages}
    body = if system, do: Map.put(body, :system, system), else: body

    body =
      if intent.tools && intent.tools != [],
        do: Map.put(body, :tools, to_anthropic_tools(intent.tools)),
        else: body

    body = if intent.temperature, do: Map.put(body, :temperature, intent.temperature), else: body

    if intent.max_tokens,
      do: Map.put(body, :max_tokens, intent.max_tokens),
      else: Map.put(body, :max_tokens, 4096)
  end

  defp extract_system(messages) do
    {system_msgs, rest} = Enum.split_while(messages, &system_role?/1)

    case system_msgs do
      [] ->
        {nil, messages}

      msgs ->
        combined =
          msgs
          |> Enum.map_join("\n\n", fn msg -> Intent.to_text(msg[:content] || []) end)

        {combined, rest}
    end
  end

  defp system_role?(%{role: :system}), do: true
  defp system_role?(%{role: "system"}), do: true
  defp system_role?(_), do: false

  defp format_messages(messages, profile) do
    messages
    |> Enum.flat_map(&format_message(&1, profile))
    |> merge_adjacent_roles()
  end

  defp format_message(%{role: role} = msg, _profile) when role in [:system, "system"] do
    [%{role: "user", content: "[System] #{Intent.to_text(msg[:content] || [])}"}]
  end

  defp format_message(%{role: role} = msg, _profile) when role in [:tool, "tool"] do
    content = Intent.to_text(msg[:content] || [])
    tool_call_id = to_string(msg[:tool_call_id] || "")
    block = %{type: "tool_result", tool_use_id: tool_call_id, content: content}
    [%{role: "user", content: [block]}]
  end

  defp format_message(%{role: role, tool_calls: tool_calls} = msg, _profile)
       when role in [:assistant, "assistant"] and is_list(tool_calls) and tool_calls != [] do
    text_blocks = text_content_blocks(msg[:content])
    tool_blocks = Enum.map(tool_calls, &to_tool_use_block/1)
    [%{role: "assistant", content: text_blocks ++ tool_blocks}]
  end

  defp format_message(%{role: role} = msg, _profile) when role in [:assistant, "assistant"] do
    [%{role: "assistant", content: Intent.to_text(msg[:content] || [])}]
  end

  defp format_message(%{role: role} = msg, _profile) when role in [:user, "user"] do
    [%{role: "user", content: serialize_content(msg[:content] || [])}]
  end

  defp format_message(msg, _profile) do
    [%{role: "user", content: serialize_content(msg[:content] || [])}]
  end

  defp text_content_blocks(content) do
    text = Intent.to_text(content || [])
    if text != "", do: [%{type: "text", text: text}], else: []
  end

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

  @doc """
  Serializes content blocks to Anthropic wire format.

  Text-only messages are sent as a plain string (single text block optimization).
  Mixed content (text + images) is sent as an array of typed objects.
  """
  def serialize_content([%{type: :text, text: text}]), do: text

  def serialize_content(blocks) when is_list(blocks) and blocks != [] do
    Enum.map(blocks, fn
      %{type: :text, text: text} ->
        %{type: "text", text: text}

      %{type: :image_url, url: url} ->
        %{type: "image", source: %{type: "url", url: url}}

      %{type: :image_base64, media_type: mt, data: data} ->
        %{type: "image", source: %{type: "base64", media_type: mt, data: data}}
    end)
  end

  def serialize_content([]), do: ""
  def serialize_content(nil), do: ""

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

  defp parse_chat_response(body) do
    %Response{
      content: extract_text_blocks(body["content"]),
      thinking: extract_thinking_content(body["content"]),
      tool_calls: extract_tool_calls(body["content"]),
      usage: parse_usage(body["usage"]),
      finish_reason: map_stop_reason(body["stop_reason"])
    }
  end

  defp extract_text_blocks(nil), do: nil

  defp extract_text_blocks(blocks) do
    text_blocks =
      blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(fn b -> %{type: :text, text: b["text"]} end)

    case text_blocks do
      [] -> nil
      blocks -> blocks
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
    %{prompt_tokens: input, completion_tokens: output, total_tokens: input + output}
  end

  defp map_stop_reason("end_turn"), do: "stop"
  defp map_stop_reason("tool_use"), do: "tool_calls"
  defp map_stop_reason("max_tokens"), do: "length"
  defp map_stop_reason(other), do: other

  defp parse_sse_stream(stream) do
    SSE.stream(stream, parse_event: &process_sse_event/1)
  end

  defp process_sse_event(%{
         "type" => "content_block_delta",
         "delta" => %{"type" => "text_delta", "text" => text}
       }) do
    {:data, %Response{content: [%{type: :text, text: text}]}}
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
    {:data, %Response{tool_calls: [%{index: index, function: %{arguments: json}}]}}
  end

  defp process_sse_event(%{
         "type" => "content_block_start",
         "content_block" => %{"type" => "tool_use", "id" => id, "name" => name},
         "index" => index
       }) do
    {:data,
     %Response{tool_calls: [%{index: index, id: id, function: %{name: name, arguments: ""}}]}}
  end

  defp process_sse_event(%{"type" => "message_stop"}), do: :done

  defp process_sse_event(%{"type" => "message_delta"} = event) do
    usage = parse_usage(event["usage"])

    {:data,
     %Response{
       usage: usage,
       finish_reason: map_stop_reason(get_in(event, ["delta", "stop_reason"]))
     }}
  end

  defp process_sse_event(_event), do: {:data, %Response{}}

  defp do_request(provider, body) do
    HTTP.client().post(HTTP.base_url_strip_v1(provider, "/v1/messages"),
      json: body,
      headers: headers(provider),
      receive_timeout: @receive_timeout
    )
  end

  defp do_stream_request(provider, body) do
    HTTP.client().post(HTTP.base_url_strip_v1(provider, "/v1/messages"),
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
end
