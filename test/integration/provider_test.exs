defmodule Arcanum.Integration.ProviderTest do
  @moduledoc """
  Integration tests against live providers.

  Excluded by default. Run with:

      # OpenAI-compatible (DeepSeek, Z.AI, OpenRouter, xAI, etc.)
      mix test --include integration

      # Vision (multimodal providers)
      mix test --include vision

      # Image generation
      mix test --include image_generation

      # Ollama
      mix test --include ollama

      # Anthropic
      mix test --include anthropic

  ## Environment Variables

  All OpenAI-compatible providers use the same env vars:

      ARCANUM_TEST_PROVIDER_URL=https://api.deepseek.com
      ARCANUM_TEST_PROVIDER_KEY=sk-...
      ARCANUM_TEST_PROVIDER_MODEL=deepseek-chat
      ARCANUM_TEST_PROVIDER_KIND=deepseek          # defaults to "openai"
      ARCANUM_TEST_PROVIDER_IMAGE_MODEL=gpt-image-1 # for image generation tests

  Ollama and Anthropic have dedicated env vars:

      ARCANUM_TEST_OLLAMA_URL=http://localhost:11434
      ARCANUM_TEST_OLLAMA_MODEL=llama3.2

      ARCANUM_TEST_ANTHROPIC_URL=https://api.anthropic.com
      ARCANUM_TEST_ANTHROPIC_KEY=sk-ant-...
      ARCANUM_TEST_ANTHROPIC_MODEL=claude-sonnet-4-20250514
  """

  use ExUnit.Case

  # Tags: :integration (OpenAI-compat), :ollama, :anthropic, :vision, :image_generation
  # All excluded by default. Run with --include <tag>.

  alias Arcanum.{Gateway, Intent, Response}

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

  defp provider_setup do
    url = System.get_env("ARCANUM_TEST_PROVIDER_URL")
    key = System.get_env("ARCANUM_TEST_PROVIDER_KEY")
    model = System.get_env("ARCANUM_TEST_PROVIDER_MODEL")
    kind = System.get_env("ARCANUM_TEST_PROVIDER_KIND") || "openai"

    if is_nil(url) or is_nil(model) do
      raise ExUnit.DocTest.Error,
        message: "ARCANUM_TEST_PROVIDER_URL and ARCANUM_TEST_PROVIDER_MODEL required"
    end

    provider = %{base_url: url, api_key: key, kind: kind, api_format: :openai}
    {:ok, provider: provider, model: model}
  end

  # -------------------------------------------------------------------
  # OpenAI-compatible providers (text-only: chat, streaming, tools)
  # -------------------------------------------------------------------

  describe "OpenAI-compatible provider" do
    @describetag :integration

    setup do
      provider_setup()
    end

    @tag timeout: 30_000
    test "simple chat completion", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Reply with exactly: PONG"}]}],
        model: model,
        temperature: 0.0
      }

      assert {:ok, %Response{} = resp} = Gateway.chat(provider, intent)
      assert Response.text(resp) =~ "PONG"
    end

    @tag timeout: 30_000
    test "chat with usage tracking", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Say hello in one word"}]}],
        model: model,
        temperature: 0.0
      }

      assert {:ok, %Response{usage: usage}} = Gateway.chat(provider, intent)
      assert usage.prompt_tokens > 0
      assert usage.completion_tokens > 0
      assert usage.total_tokens >= usage.prompt_tokens + usage.completion_tokens
    end

    @tag timeout: 30_000
    test "tool call", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [
          %{role: :user, content: [%{type: :text, text: "What's the weather in Tokyo?"}]}
        ],
        model: model,
        tools: [@tool_weather],
        temperature: 0.0
      }

      assert {:ok, %Response{} = resp} = Gateway.chat(provider, intent)

      if resp.tool_calls && resp.tool_calls != [] do
        [call | _] = resp.tool_calls
        assert call.function.name == "get_weather"
        args = Jason.decode!(call.function.arguments)
        assert is_binary(args["city"])
      end
    end

    @tag timeout: 30_000
    test "multi-turn conversation", %{provider: provider, model: model} do
      messages = [
        %{role: :user, content: [%{type: :text, text: "My name is Arcanum."}]},
        %{role: :assistant, content: [%{type: :text, text: "Nice to meet you, Arcanum!"}]},
        %{
          role: :user,
          content: [%{type: :text, text: "What is my name? Reply with just the name."}]
        }
      ]

      intent = %Intent{messages: messages, model: model, temperature: 0.0}
      assert {:ok, %Response{} = resp} = Gateway.chat(provider, intent)
      assert Response.text(resp) =~ "Arcanum"
    end

    @tag timeout: 60_000
    test "streaming", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Count from 1 to 3"}]}],
        model: model,
        temperature: 0.0
      }

      assert {:ok, stream} = Gateway.stream(provider, intent)

      chunks = Enum.to_list(stream)
      assert chunks != []

      data_chunks = Enum.filter(chunks, &match?({:data, %Response{}}, &1))
      assert data_chunks != []
    end

    @tag timeout: 30_000
    test "list models", %{provider: provider} do
      case Gateway.list_models(provider) do
        {:ok, models} ->
          assert is_list(models)
          assert models != []
          assert Enum.all?(models, &is_binary/1)

        {:error, _} ->
          :ok
      end
    end
  end

  # -------------------------------------------------------------------
  # Vision (multimodal providers)
  # -------------------------------------------------------------------

  describe "OpenAI-compatible provider vision" do
    @describetag :vision

    setup do
      provider_setup()
    end

    @tag timeout: 30_000
    test "vision with image", %{provider: provider, model: model} do
      image_path = Path.join([__DIR__, "..", "assets", "color_test.png"])
      base64 = image_path |> File.read!() |> Base.encode64()

      intent = %Intent{
        messages: [
          %{
            role: :user,
            content: [
              %{type: :text, text: "What color is this image? Reply with one word."},
              %{type: :image_base64, media_type: "image/png", data: base64}
            ]
          }
        ],
        model: model,
        temperature: 0.0,
        max_tokens: 50
      }

      assert {:ok, %Response{content: content}} = Gateway.chat(provider, intent)
      assert [_ | _] = content
      assert Response.text(%Response{content: content}) != nil
    end
  end

  # -------------------------------------------------------------------
  # Image generation
  # -------------------------------------------------------------------

  describe "OpenAI-compatible provider image generation" do
    @describetag :image_generation

    setup do
      url = System.get_env("ARCANUM_TEST_PROVIDER_URL")
      key = System.get_env("ARCANUM_TEST_PROVIDER_KEY")
      kind = System.get_env("ARCANUM_TEST_PROVIDER_KIND") || "openai"

      if is_nil(url) do
        raise ExUnit.DocTest.Error,
          message: "ARCANUM_TEST_PROVIDER_URL required"
      end

      provider = %{base_url: url, api_key: key, kind: kind, api_format: :openai}
      {:ok, provider: provider}
    end

    @tag timeout: 60_000
    test "image generation", %{provider: provider} do
      image_model =
        System.get_env("ARCANUM_TEST_PROVIDER_IMAGE_MODEL") || "gpt-image-1"

      intent = %Intent{
        model: image_model,
        prompt: "A solid red square on a white background",
        size: "1024x1024",
        n: 1
      }

      case Gateway.generate_image(provider, intent) do
        {:ok, %Response{content: blocks}} ->
          assert [_ | _] = blocks

          Enum.each(blocks, fn block ->
            assert block.type == :image
            assert is_binary(block.data)
            assert block.data != ""
          end)

        {:error, {:api_error, 403, _}} ->
          # Account may not have image generation access
          :ok

        {:error, {:api_error, 429, _}} ->
          # Rate limited
          :ok
      end
    end
  end

  # -------------------------------------------------------------------
  # Ollama
  # -------------------------------------------------------------------

  describe "Ollama provider" do
    @describetag :ollama

    setup do
      provider = %{
        base_url: System.get_env("ARCANUM_TEST_OLLAMA_URL"),
        api_key: nil,
        kind: "ollama",
        api_format: :custom
      }

      {:ok, provider: provider, model: System.get_env("ARCANUM_TEST_OLLAMA_MODEL")}
    end

    @tag timeout: 60_000
    test "simple chat completion", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Reply with exactly: PONG"}]}],
        model: model,
        temperature: 0.0
      }

      assert {:ok, %Response{content: content}} = Gateway.chat(provider, intent)
      assert [_ | _] = content
      assert Response.text(%Response{content: content}) != nil
    end

    @tag timeout: 30_000
    test "list models", %{provider: provider} do
      assert {:ok, models} = Gateway.list_models(provider)
      assert is_list(models)
      assert models != []
    end
  end

  # -------------------------------------------------------------------
  # Anthropic
  # -------------------------------------------------------------------

  describe "Anthropic provider" do
    @describetag :anthropic

    setup do
      provider = %{
        base_url: System.get_env("ARCANUM_TEST_ANTHROPIC_URL"),
        api_key: System.get_env("ARCANUM_TEST_ANTHROPIC_KEY"),
        kind: "anthropic",
        api_format: :anthropic
      }

      {:ok, provider: provider, model: System.get_env("ARCANUM_TEST_ANTHROPIC_MODEL")}
    end

    @tag timeout: 30_000
    test "simple chat completion", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: [%{type: :text, text: "Reply with exactly: PONG"}]}],
        model: model,
        temperature: 0.0,
        max_tokens: 100
      }

      assert {:ok, %Response{} = resp} = Gateway.chat(provider, intent)
      assert Response.text(resp) =~ "PONG"
    end

    @tag timeout: 30_000
    test "tool call", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [
          %{role: :user, content: [%{type: :text, text: "What's the weather in Paris?"}]}
        ],
        model: model,
        tools: [@tool_weather],
        temperature: 0.0,
        max_tokens: 200
      }

      assert {:ok, %Response{} = resp} = Gateway.chat(provider, intent)

      if resp.tool_calls && resp.tool_calls != [] do
        [call | _] = resp.tool_calls
        assert call.function.name == "get_weather"
      end
    end
  end
end
