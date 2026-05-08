defmodule Arcanum.Adapters.Anthropic do
  @moduledoc """
  Inference adapter for the Anthropic Messages API.

  Handles Anthropic-specific request/response format differences
  (system as top-level param, content blocks, etc.).
  """

  @behaviour Arcanum.Provider

  alias Arcanum.{Intent, ModelProfile, Response}

  @anthropic_version "2023-06-01"

  # LLM inference can take a while
  @receive_timeout :timer.minutes(5)

  @impl true
  def chat(provider, %Intent{} = intent, %ModelProfile{} = _profile) do
    body = build_chat_body(intent)

    case http_client().post(base_url(provider, "/v1/messages"),
           json: body,
           headers: headers(provider),
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
    body = Map.put(build_chat_body(intent), :stream, true)

    case http_client().post(base_url(provider, "/v1/messages"),
           json: body,
           headers: headers(provider),
           into: :self,
           receive_timeout: @receive_timeout
         ) do
      {:ok, %{status: 200, body: stream}} ->
        {:ok, parse_sse_stream(stream)}

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

  defp build_chat_body(%Intent{} = intent) do
    {system, messages} = extract_system(intent.messages)

    body = %{model: intent.model, messages: messages}

    body = if system, do: Map.put(body, :system, system), else: body

    body =
      if intent.tools, do: Map.put(body, :tools, to_anthropic_tools(intent.tools)), else: body

    body =
      if intent.temperature, do: Map.put(body, :temperature, intent.temperature), else: body

    body =
      if intent.max_tokens,
        do: Map.put(body, :max_tokens, intent.max_tokens),
        else: Map.put(body, :max_tokens, 4096)

    body
  end

  defp extract_system(messages) do
    case messages do
      [%{role: "system", content: content} | rest] -> {content, rest}
      _ -> {nil, messages}
    end
  end

  defp to_anthropic_tools(tools) do
    Enum.map(tools, fn tool ->
      func = tool.function || tool[:function]

      %{
        name: func.name || func[:name],
        description: func.description || func[:description],
        input_schema: func.parameters || func[:parameters]
      }
    end)
  end

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

  defp parse_sse_stream(stream) do
    Stream.transform(stream, %{content: "", tool_calls: []}, fn
      chunk, acc ->
        events = parse_sse_chunk(chunk)
        process_events(events, acc)
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
      {:ok, event} -> [event]
      {:error, _} -> []
    end
  end

  defp parse_sse_line(_), do: []

  defp process_events(events, acc) do
    Enum.reduce(events, {[], acc}, fn event, {emissions, acc} ->
      {new_emissions, new_acc} = process_event(event, acc)
      {emissions ++ new_emissions, new_acc}
    end)
  end

  defp process_event(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}},
         acc
       ) do
    {[{:data, %Response{content: text}}], acc}
  end

  defp process_event(%{"type" => "content_block_delta"}, acc), do: {[], acc}

  defp process_event(%{"type" => "message_stop"}, acc), do: {[:done], acc}

  defp process_event(%{"type" => "message_delta"} = event, acc) do
    usage = parse_usage(event["usage"])

    response = %Response{
      usage: usage,
      finish_reason: map_stop_reason(event["delta"]["stop_reason"])
    }

    {[{:data, response}], acc}
  end

  defp process_event(_event, acc), do: {[], acc}

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
end
