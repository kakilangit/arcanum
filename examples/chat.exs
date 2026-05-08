#!/usr/bin/env elixir
# Usage:
#   PROVIDER_BASE_URL=http://localhost:11434 PROVIDER_MODEL=llama3.2 elixir examples/chat.exs
#   PROVIDER_BASE_URL=https://api.deepseek.com PROVIDER_API_KEY=sk-... PROVIDER_MODEL=deepseek-chat elixir examples/chat.exs
#   PROVIDER_BASE_URL=https://api.openai.com PROVIDER_API_KEY=sk-... PROVIDER_MODEL=gpt-4o elixir examples/chat.exs
#
# Environment variables:
#   PROVIDER_BASE_URL  — required, e.g. https://api.deepseek.com
#   PROVIDER_API_KEY   — optional, for authenticated providers
#   PROVIDER_MODEL     — required, e.g. deepseek-chat
#   PROVIDER_KIND      — optional, defaults to "openai"
#   PROVIDER_FORMAT    — optional, defaults to "openai" (openai|anthropic|custom)

Mix.install([
  {:arcanum, path: Path.expand("..", __DIR__)}
])

defmodule Chat do
  alias Arcanum.{Gateway, Intent, Response}

  @max_turns 50

  def run do
    provider = build_provider()
    model = required_env("PROVIDER_MODEL")

    IO.puts("Arcanum Chat — #{provider.kind}@#{provider.base_url}")
    IO.puts("Model: #{model}")
    IO.puts("Type 'exit' to quit, 'clear' to reset history.\n")

    loop(provider, model, [])
  end

  defp loop(_provider, _model, _history, turn \\ 0)

  defp loop(_provider, _model, _history, turn) when turn >= @max_turns do
    IO.puts("\n[Max #{@max_turns} turns reached]")
  end

  defp loop(provider, model, history, turn) do
    input = IO.gets("you> ") |> String.trim()

    case input do
      "exit" ->
        IO.puts("Bye!")

      "clear" ->
        IO.puts("[History cleared]")
        loop(provider, model, [], 0)

      "" ->
        loop(provider, model, history, turn)

      user_msg ->
        messages = history ++ [%{role: :user, content: user_msg}]
        intent = %Intent{messages: messages, model: model}

        case Gateway.chat(provider, intent) do
          {:ok, %Response{content: content, thinking: thinking, usage: usage}} ->
            if thinking && thinking != "", do: IO.puts("\n[thinking] #{thinking}")
            IO.puts("\nassistant> #{content || "(no content)"}")

            if usage do
              IO.puts(
                "[tokens: #{usage.prompt_tokens} in / #{usage.completion_tokens} out / #{usage.total_tokens} total]"
              )
            end

            IO.puts("")
            updated = messages ++ [%{role: :assistant, content: content || ""}]
            loop(provider, model, updated, turn + 1)

          {:error, reason} ->
            IO.puts("\n[error] #{inspect(reason)}\n")
            loop(provider, model, history, turn)
        end
    end
  end

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

Chat.run()
