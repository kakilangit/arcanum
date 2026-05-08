defmodule Arcanum.Integration.ProviderTest do
  @moduledoc """
  Integration tests against live providers.

  Excluded by default. Run with:

      mix test --include integration

  ## Environment Variables

      # OpenAI-compatible (DeepSeek, Z.AI, OpenRouter, etc.)
      ARCANUM_TEST_OPENAI_URL=https://api.deepseek.com
      ARCANUM_TEST_OPENAI_KEY=sk-...
      ARCANUM_TEST_OPENAI_MODEL=deepseek-chat

      # Ollama (local)
      ARCANUM_TEST_OLLAMA_URL=http://localhost:11434
      ARCANUM_TEST_OLLAMA_MODEL=llama3.2

      # Anthropic
      ARCANUM_TEST_ANTHROPIC_URL=https://api.anthropic.com
      ARCANUM_TEST_ANTHROPIC_KEY=sk-ant-...
      ARCANUM_TEST_ANTHROPIC_MODEL=claude-sonnet-4-20250514
  """

  use ExUnit.Case

  @moduletag :integration

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

  # -------------------------------------------------------------------
  # OpenAI-compatible providers
  # -------------------------------------------------------------------

  describe "OpenAI-compatible provider" do
    setup do
      url = System.get_env("ARCANUM_TEST_OPENAI_URL")
      key = System.get_env("ARCANUM_TEST_OPENAI_KEY")
      model = System.get_env("ARCANUM_TEST_OPENAI_MODEL")

      if is_nil(url) or is_nil(model) do
        raise ExUnit.DocTest.Error,
          message: "ARCANUM_TEST_OPENAI_URL and ARCANUM_TEST_OPENAI_MODEL required"
      end

      provider = %{base_url: url, api_key: key, kind: "openai", api_format: :openai}
      {:ok, provider: provider, model: model}
    end

    @tag timeout: 30_000
    test "simple chat completion", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: "Reply with exactly: PONG"}],
        model: model,
        temperature: 0.0
      }

      assert {:ok, %Response{content: content}} = Gateway.chat(provider, intent)
      assert content =~ "PONG"
    end

    @tag timeout: 30_000
    test "chat with usage tracking", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: "Say hello in one word"}],
        model: model,
        temperature: 0.0
      }

      assert {:ok, %Response{usage: usage}} = Gateway.chat(provider, intent)
      assert usage.prompt_tokens > 0
      assert usage.completion_tokens > 0
      assert usage.total_tokens == usage.prompt_tokens + usage.completion_tokens
    end

    @tag timeout: 30_000
    test "tool call", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: "What's the weather in Tokyo?"}],
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
        %{role: :user, content: "My name is Arcanum."},
        %{role: :assistant, content: "Nice to meet you, Arcanum!"},
        %{role: :user, content: "What is my name? Reply with just the name."}
      ]

      intent = %Intent{messages: messages, model: model, temperature: 0.0}
      assert {:ok, %Response{content: content}} = Gateway.chat(provider, intent)
      assert content =~ "Arcanum"
    end

    @tag timeout: 60_000
    test "streaming", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: "Count from 1 to 3"}],
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
  # Ollama
  # -------------------------------------------------------------------

  describe "Ollama provider" do
    setup do
      url = System.get_env("ARCANUM_TEST_OLLAMA_URL")
      model = System.get_env("ARCANUM_TEST_OLLAMA_MODEL")

      if is_nil(url) or is_nil(model) do
        raise ExUnit.DocTest.Error,
          message: "ARCANUM_TEST_OLLAMA_URL and ARCANUM_TEST_OLLAMA_MODEL required"
      end

      provider = %{base_url: url, api_key: nil, kind: "ollama", api_format: :custom}
      {:ok, provider: provider, model: model}
    end

    @tag timeout: 60_000
    test "simple chat completion", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: "Reply with exactly: PONG"}],
        model: model,
        temperature: 0.0
      }

      assert {:ok, %Response{content: content}} = Gateway.chat(provider, intent)
      assert is_binary(content)
      assert String.length(content) > 0
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
    setup do
      url = System.get_env("ARCANUM_TEST_ANTHROPIC_URL")
      key = System.get_env("ARCANUM_TEST_ANTHROPIC_KEY")
      model = System.get_env("ARCANUM_TEST_ANTHROPIC_MODEL")

      if is_nil(url) or is_nil(key) or is_nil(model) do
        raise ExUnit.DocTest.Error,
          message: "ARCANUM_TEST_ANTHROPIC_URL, KEY, and MODEL required"
      end

      provider = %{base_url: url, api_key: key, kind: "anthropic", api_format: :anthropic}
      {:ok, provider: provider, model: model}
    end

    @tag timeout: 30_000
    test "simple chat completion", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: "Reply with exactly: PONG"}],
        model: model,
        temperature: 0.0,
        max_tokens: 100
      }

      assert {:ok, %Response{content: content}} = Gateway.chat(provider, intent)
      assert content =~ "PONG"
    end

    @tag timeout: 30_000
    test "tool call", %{provider: provider, model: model} do
      intent = %Intent{
        messages: [%{role: :user, content: "What's the weather in Paris?"}],
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
