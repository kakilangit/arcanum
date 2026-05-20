defmodule ArcanumeTest do
  use ExUnit.Case, async: true

  alias Arcanum.Adapters.{Anthropic, Ollama, OpenAI}

  describe "adapter_for/1" do
    test "openai format as atom" do
      assert Arcanum.adapter_for(%{api_format: :openai}) == OpenAI
    end

    test "openai format as string" do
      assert Arcanum.adapter_for(%{api_format: "openai"}) == OpenAI
    end

    test "anthropic format as atom" do
      assert Arcanum.adapter_for(%{api_format: :anthropic}) == Anthropic
    end

    test "anthropic format as string" do
      assert Arcanum.adapter_for(%{api_format: "anthropic"}) == Anthropic
    end

    test "ollama kind as string" do
      assert Arcanum.adapter_for(%{kind: "ollama", api_format: :custom}) == Ollama
    end

    test "ollama kind as atom" do
      assert Arcanum.adapter_for(%{kind: :ollama, api_format: :custom}) == Ollama
    end

    test "ollama kind without api_format" do
      assert Arcanum.adapter_for(%{kind: :ollama}) == Ollama
    end

    test "github-copilot kind as string" do
      assert Arcanum.adapter_for(%{kind: "github-copilot"}) == OpenAI
    end

    test "github-copilot kind as atom" do
      assert Arcanum.adapter_for(%{kind: :"github-copilot"}) == OpenAI
    end

    test "custom format falls back to OpenAI" do
      assert Arcanum.adapter_for(%{api_format: :custom, kind: "other"}) == OpenAI
    end

    test "custom format as string falls back to OpenAI" do
      assert Arcanum.adapter_for(%{api_format: "custom", kind: "other"}) == OpenAI
    end
  end
end
