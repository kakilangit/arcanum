#!/usr/bin/env elixir
# Lists models from all target providers.
# Usage: source ../.env && elixir test/list_models.exs

Mix.install([
  {:arcanum, path: Path.expand("..", __DIR__)}
])

alias Arcanum.Gateway

providers = [
  {"Anthropic",
   %{
     base_url: "https://api.anthropic.com",
     api_key: System.get_env("ANTHROPIC_KEY"),
     kind: "anthropic",
     api_format: :anthropic
   }},
  {"OpenAI",
   %{
     base_url: "https://api.openai.com/v1",
     api_key: System.get_env("OPENAPI_KEY"),
     kind: "openai",
     api_format: :openai
   }},
  {"xAI",
   %{
     base_url: "https://api.x.ai/v1",
     api_key: System.get_env("XAI_KEY"),
     kind: "xai",
     api_format: :openai
   }},
  {"DeepSeek",
   %{
     base_url: "https://api.deepseek.com",
     api_key: System.get_env("DEEPSEEK_KEY"),
     kind: "deepseek",
     api_format: :openai
   }},
  {"Z.AI",
   %{
     base_url: "https://api.z.ai/api/coding/paas/v4",
     api_key: System.get_env("ZAI_KEY"),
     kind: "zai",
     api_format: :openai
   }}
]

for {name, provider} <- providers do
  IO.puts("\n=== #{name} ===")

  case Gateway.list_models(provider) do
    {:ok, models} ->
      models |> Enum.sort() |> Enum.each(&IO.puts("  #{&1}"))
      IO.puts("  (#{length(models)} models)")

    {:error, reason} ->
      IO.puts("  ERROR: #{inspect(reason)}")
  end
end
