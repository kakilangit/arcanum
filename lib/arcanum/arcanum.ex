defmodule Arcanum do
  @moduledoc """
  Entry point for the inference layer.

  Routes requests to the correct adapter based on the provider's `api_format`.
  """

  alias Arcanum.Adapters.{Anthropic, Ollama, OpenAI}

  @doc """
  Returns the adapter module for the given provider.
  """
  def adapter_for(%{api_format: :openai}), do: OpenAI
  def adapter_for(%{api_format: :anthropic}), do: Anthropic

  def adapter_for(%{kind: "ollama"}), do: Ollama
  def adapter_for(%{api_format: :custom, kind: "ollama"}), do: Ollama

  # Copilot uses OpenAI-compatible API with extra headers
  def adapter_for(%{kind: "github-copilot"}), do: OpenAI

  # Custom providers with openai/anthropic-compatible APIs
  def adapter_for(%{api_format: :custom}), do: OpenAI
end
