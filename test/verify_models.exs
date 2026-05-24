#!/usr/bin/env elixir
# Arcanum Model Verification — Comprehensive check of all models across providers.
#
# Tests each model for: chat, tool_call, streaming.
# Reports pass/fail/error per model per capability.
#
# Usage:
#   set -a && source ../.env && set +a
#   elixir test/verify_models.exs
#   elixir test/verify_models.exs --provider openai
#   elixir test/verify_models.exs --provider anthropic --provider xai

Mix.install([
  {:arcanum, path: Path.expand("..", __DIR__)}
])

defmodule Arcanum.Verify do
  @moduledoc """
  Comprehensive model verification across providers.

  Each provider defines its connection config and chat-capable model list.
  Each model is tested against a standard capability matrix:
  chat, tool_call, streaming.
  """

  alias Arcanum.{Gateway, Intent, Response}

  # -------------------------------------------------------------------
  # Provider registry — connection config + chat-capable models
  # -------------------------------------------------------------------

  defp providers do
    %{
      "anthropic" => %{
        connection: %{
          base_url: "https://api.anthropic.com",
          api_key: System.get_env("ANTHROPIC_KEY"),
          kind: "anthropic",
          api_format: :anthropic
        },
        models: [
          "claude-haiku-4-5-20251001",
          "claude-sonnet-4-20250514",
          "claude-sonnet-4-5-20250929",
          "claude-sonnet-4-6",
          "claude-opus-4-20250514",
          "claude-opus-4-1-20250805",
          "claude-opus-4-5-20251101",
          "claude-opus-4-6",
          "claude-opus-4-7"
        ]
      },
      "openai" => %{
        connection: %{
          base_url: "https://api.openai.com/v1",
          api_key: System.get_env("OPENAPI_KEY"),
          kind: "openai",
          api_format: :openai
        },
        models: [
          "gpt-4o",
          "gpt-4o-mini",
          "gpt-4.1",
          "gpt-4.1-mini",
          "gpt-4.1-nano",
          "gpt-5",
          "gpt-5-mini",
          "gpt-5-nano",
          "gpt-5-pro",
          "gpt-5.1",
          "gpt-5.2",
          "gpt-5.2-pro",
          "gpt-5.4",
          "gpt-5.4-mini",
          "gpt-5.4-nano",
          "gpt-5.4-pro",
          "gpt-5.5",
          "gpt-5.5-pro",
          "o1",
          "o3",
          "o3-mini",
          "o4-mini"
        ]
      },
      "xai" => %{
        connection: %{
          base_url: "https://api.x.ai/v1",
          api_key: System.get_env("XAI_KEY"),
          kind: "xai",
          api_format: :openai
        },
        models: [
          "grok-4.3",
          "grok-4.20-0309-non-reasoning",
          "grok-4.20-0309-reasoning"
        ]
      },
      "deepseek" => %{
        connection: %{
          base_url: "https://api.deepseek.com",
          api_key: System.get_env("DEEPSEEK_KEY"),
          kind: "deepseek",
          api_format: :openai
        },
        models: [
          "deepseek-v4-flash",
          "deepseek-v4-pro"
        ]
      },
      "zai" => %{
        connection: %{
          base_url: "https://api.z.ai/api/coding/paas/v4",
          api_key: System.get_env("ZAI_KEY"),
          kind: "zai",
          api_format: :openai
        },
        models: [
          "glm-4.5",
          "glm-4.5-air",
          "glm-4.6",
          "glm-4.7",
          "glm-5",
          "glm-5-turbo",
          "glm-5.1"
        ]
      }
    }
  end

  @tool_weather %{
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
  }

  # -------------------------------------------------------------------
  # Capability checks — each returns {:pass, detail} | {:fail, reason}
  # -------------------------------------------------------------------

  defp check_chat(provider, model) do
    intent = %Intent{
      messages: [%{role: :user, content: [%{type: :text, text: "Reply with exactly: PONG"}]}],
      model: model,
      temperature: 0.0,
      max_tokens: 100
    }

    case Gateway.chat(provider, intent) do
      {:ok, %Response{} = resp} ->
        text = Response.text(resp) || ""

        if String.contains?(text, "PONG"),
          do: {:pass, "got PONG"},
          else: {:pass, "response ok (#{String.slice(text, 0..30)})"}

      {:error, reason} ->
        {:fail, inspect(reason)}
    end
  rescue
    e -> {:fail, "exception: #{Exception.message(e)}"}
  catch
    kind, value -> {:fail, "#{kind}: #{inspect(value)}"}
  end

  defp check_tool_call(provider, model) do
    intent = %Intent{
      messages: [
        %{role: :user, content: [%{type: :text, text: "What's the weather in Tokyo?"}]}
      ],
      model: model,
      tools: [@tool_weather],
      temperature: 0.0,
      max_tokens: 200
    }

    case Gateway.chat(provider, intent) do
      {:ok, %Response{tool_calls: [call | _]}} ->
        if call.function.name == "get_weather",
          do: {:pass, "called get_weather(#{call.function.arguments})"},
          else: {:pass, "called #{call.function.name}"}

      {:ok, %Response{tool_calls: nil} = resp} ->
        text = Response.text(resp) || ""
        {:fail, "no tool calls, got text: #{String.slice(text, 0..50)}"}

      {:ok, %Response{tool_calls: []}} ->
        {:fail, "empty tool_calls (malformed filtered?)"}

      {:error, reason} ->
        {:fail, inspect(reason)}
    end
  rescue
    e -> {:fail, "exception: #{Exception.message(e)}"}
  catch
    kind, value -> {:fail, "#{kind}: #{inspect(value)}"}
  end

  defp check_streaming(provider, model) do
    intent = %Intent{
      messages: [%{role: :user, content: [%{type: :text, text: "Say hello"}]}],
      model: model,
      temperature: 0.0,
      max_tokens: 100
    }

    case Gateway.stream(provider, intent) do
      {:ok, stream} ->
        chunks = Enum.to_list(stream)
        data_chunks = Enum.filter(chunks, &match?({:data, %Response{}}, &1))

        if data_chunks != [],
          do: {:pass, "#{length(data_chunks)} data chunks"},
          else: {:fail, "stream returned but no data chunks"}

      {:error, reason} ->
        {:fail, inspect(reason)}
    end
  rescue
    e -> {:fail, "exception: #{Exception.message(e)}"}
  catch
    kind, value -> {:fail, "#{kind}: #{inspect(value)}"}
  end

  # -------------------------------------------------------------------
  # Runner
  # -------------------------------------------------------------------

  defp capabilities do
    [
      {:chat, &check_chat/2},
      {:tool_call, &check_tool_call/2},
      {:streaming, &check_streaming/2}
    ]
  end

  def run(filter_providers) do
    all = providers()

    providers =
      if filter_providers == [] do
        all
      else
        Map.take(all, filter_providers)
      end

    results =
      for {name, config} <- Enum.sort(providers) do
        provider = config.connection
        IO.puts("\n#{IO.ANSI.bright()}=== #{name} ===#{IO.ANSI.reset()}")
        IO.puts("  #{provider.base_url}\n")

        model_results =
          for model <- config.models do
            verify_model(provider, model)
          end

        {name, model_results}
      end

    print_summary(results)
    results
  end

  defp verify_model(provider, model) do
    IO.write("  #{model}")

    cap_results =
      for {cap_name, check_fn} <- capabilities() do
        run_capability(provider, model, cap_name, check_fn)
      end

    IO.puts("")

    for {cap_name, {:fail, reason}} <- cap_results do
      IO.puts("    #{IO.ANSI.red()}└ #{cap_name}: #{reason}#{IO.ANSI.reset()}")
    end

    {model, Map.new(cap_results)}
  end

  defp run_capability(provider, model, cap_name, check_fn) do
    result = check_fn.(provider, model)
    icon = if match?({:pass, _}, result), do: "✓", else: "✗"
    color = if match?({:pass, _}, result), do: IO.ANSI.green(), else: IO.ANSI.red()
    IO.write(" #{color}#{icon}#{cap_name}#{IO.ANSI.reset()}")
    {cap_name, result}
  end

  defp print_summary(results) do
    IO.puts(
      "\n#{IO.ANSI.bright()}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━#{IO.ANSI.reset()}"
    )

    IO.puts("#{IO.ANSI.bright()}SUMMARY#{IO.ANSI.reset()}")
    IO.puts("#{IO.ANSI.bright()}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━#{IO.ANSI.reset()}")

    {total_pass, total_fail} =
      for {provider, models} <- results, reduce: {0, 0} do
        {tp, tf} ->
          {pp, ff} = count_results(models)
          print_provider_counts(provider, pp, ff)
          {tp + pp, tf + ff}
      end

    IO.puts("")

    IO.puts(
      "  Total: #{IO.ANSI.green()}#{total_pass} pass#{IO.ANSI.reset()} / #{IO.ANSI.red()}#{total_fail} fail#{IO.ANSI.reset()}"
    )

    print_needs_customization(results)

    IO.puts("#{IO.ANSI.bright()}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━#{IO.ANSI.reset()}")
  end

  defp count_results(models) do
    for {_model, caps} <- models, {_cap, result} <- caps, reduce: {0, 0} do
      {p, f} ->
        case result do
          {:pass, _} -> {p + 1, f}
          {:fail, _} -> {p, f + 1}
        end
    end
  end

  defp print_provider_counts(provider, pass, fail) do
    IO.puts(
      "  #{provider}: #{IO.ANSI.green()}#{pass} pass#{IO.ANSI.reset()} / #{IO.ANSI.red()}#{fail} fail#{IO.ANSI.reset()}"
    )
  end

  defp print_needs_customization(results) do
    needs_work =
      for {provider, models} <- results,
          {model, caps} <- models,
          {cap, {:fail, reason}} <- caps do
        {provider, model, cap, reason}
      end

    if needs_work != [] do
      IO.puts("\n#{IO.ANSI.bright()}NEEDS CUSTOMIZATION#{IO.ANSI.reset()}")

      for {provider, model, cap, reason} <- needs_work do
        IO.puts("  #{provider}/#{model} [#{cap}]: #{String.slice(reason, 0..80)}")
      end
    end
  end
end

# Parse CLI args
filter_providers =
  System.argv()
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.flat_map(fn
    ["--provider", name] -> [name]
    _ -> []
  end)

Arcanum.Verify.run(filter_providers)
