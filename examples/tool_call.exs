#!/usr/bin/env elixir
# Tool-call round-trip example — demonstrates a minimal ReAct loop.
#
# Usage:
#   PROVIDER_BASE_URL=https://api.deepseek.com PROVIDER_API_KEY=sk-... PROVIDER_MODEL=deepseek-chat elixir examples/tool_call.exs

Mix.install([
  {:arcanum, path: Path.expand("..", __DIR__)}
])

defmodule ToolCallExample do
  alias Arcanum.{Gateway, Intent, Response}

  @max_steps 5

  @tools [
    %{
      type: "function",
      function: %{
        name: "get_weather",
        description: "Get current weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["city"],
          "additionalProperties" => false
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "calculate",
        description: "Evaluate a math expression",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "expression" => %{"type" => "string", "description" => "Math expression, e.g. 2+2"}
          },
          "required" => ["expression"],
          "additionalProperties" => false
        }
      }
    }
  ]

  def run do
    provider = build_provider()
    model = required_env("PROVIDER_MODEL")
    query = Enum.join(System.argv(), " ")
    query = if query == "", do: "What's the weather in Tokyo and Berlin?", else: query

    IO.puts("Arcanum Tool Call — #{provider.kind}@#{provider.base_url}")
    IO.puts("Model: #{model}")
    IO.puts("Query: #{query}\n")

    messages = [%{role: :user, content: Intent.text(query)}]
    react_loop(provider, model, messages, 0)
  end

  defp react_loop(_provider, _model, _messages, step) when step >= @max_steps do
    IO.puts("\n[Max #{@max_steps} steps reached]")
  end

  defp react_loop(provider, model, messages, step) do
    intent = %Intent{messages: messages, model: model, tools: @tools, temperature: 0.0}

    IO.puts("[step #{step + 1}] Calling LLM...")

    case Gateway.chat(provider, intent) do
      {:ok, %Response{tool_calls: tool_calls} = resp}
      when is_list(tool_calls) and tool_calls != [] ->
        IO.puts("[step #{step + 1}] #{length(tool_calls)} tool call(s)")

        # Add assistant message with tool calls
        assistant_msg = %{role: :assistant, content: resp.content || [], tool_calls: tool_calls}

        # Execute each tool and collect results
          tool_results =
          Enum.map(tool_calls, fn call ->
            IO.puts("  -> #{call.function.name}(#{call.function.arguments})")
            result = execute_tool(call.function.name, call.function.arguments)
            IO.puts("  <- #{result}")
            %{role: :tool, content: Intent.text(result), tool_call_id: call.id}
          end)

        react_loop(provider, model, messages ++ [assistant_msg] ++ tool_results, step + 1)

      {:ok, %Response{} = resp} ->
        IO.puts("\n[Final answer]\n#{Response.text(resp)}")

      {:error, reason} ->
        IO.puts("\n[error] #{inspect(reason)}")
    end
  end

  defp execute_tool("get_weather", args_json) do
    case Jason.decode(args_json) do
      {:ok, %{"city" => city}} ->
        # Fake weather data
        temp = :rand.uniform(35)
        conditions = Enum.random(["sunny", "cloudy", "rainy", "windy", "snowy"])
        "#{city}: #{temp}°C, #{conditions}"

      _ ->
        "Error: invalid arguments"
    end
  end

  defp execute_tool("calculate", args_json) do
    case Jason.decode(args_json) do
      {:ok, %{"expression" => expr}} ->
        # Safe eval via Code.eval_string (for demo only)
        try do
          {result, _} = Code.eval_string(expr)
          "#{result}"
        rescue
          e -> "Error: #{Exception.message(e)}"
        end

      _ ->
        "Error: invalid arguments"
    end
  end

  defp execute_tool(name, _args), do: "Error: unknown tool #{name}"

  defp build_provider do
    format =
      case System.get_env("PROVIDER_FORMAT", "openai") do
        "anthropic" -> :anthropic
        "custom" -> :custom
        _ -> :openai
      end

    %{
      base_url: required_env("PROVIDER_BASE_URL"),
      api_key: System.get_env("PROVIDER_API_KEY"),
      kind: System.get_env("PROVIDER_KIND", "openai"),
      api_format: format
    }
  end

  defp required_env(key) do
    System.get_env(key) || raise "Missing required env var: #{key}"
  end
end

ToolCallExample.run()
