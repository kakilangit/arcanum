#!/usr/bin/env elixir
# Streaming example — shows tokens arriving in real-time.
#
# Usage:
#   PROVIDER_BASE_URL=https://api.deepseek.com PROVIDER_API_KEY=sk-... PROVIDER_MODEL=deepseek-chat elixir examples/stream.exs "Explain BEAM in 3 sentences"

Mix.install([
  {:arcanum, path: Path.expand("..", __DIR__)}
])

defmodule StreamExample do
  alias Arcanum.{Gateway, Intent, Response}

  def run do
    provider = build_provider()
    model = required_env("PROVIDER_MODEL")
    query = Enum.join(System.argv(), " ")
    query = if query == "", do: "Write a haiku about Elixir", else: query

    IO.puts("Arcanum Stream — #{provider.kind}@#{provider.base_url}")
    IO.puts("Model: #{model}")
    IO.puts("---\n")

    intent = %Intent{
      messages: [%{role: :user, content: Intent.text(query)}],
      model: model,
      temperature: 0.7
    }

    case Gateway.stream(provider, intent) do
      {:ok, stream} ->
        stream
        |> Enum.each(fn
          {:data, %Response{content: [%{type: :text, text: text} | _]}} when text != "" ->
            IO.write(text)

          {:data, %Response{thinking: thinking}} when is_binary(thinking) and thinking != "" ->
            IO.write(IO.ANSI.faint() <> thinking <> IO.ANSI.reset())

          _ ->
            :ok
        end)

        IO.puts("\n\n---\n[done]")

      {:error, reason} ->
        IO.puts("[error] #{inspect(reason)}")
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

StreamExample.run()
