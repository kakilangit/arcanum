defmodule Arcanum do
  @moduledoc """
  Entry point for the inference layer.

  Routes requests to the correct adapter based on the provider's `api_format`.
  """

  alias Arcanum.Adapters.{Anthropic, Grimoire, Ollama, OpenAI}

  @doc """
  Returns the adapter module for the given provider.
  """
  def adapter_for(%{api_format: format}) when format in [:grimoire, "grimoire"], do: Grimoire
  def adapter_for(%{api_format: format}) when format in [:openai, "openai"], do: OpenAI
  def adapter_for(%{api_format: format}) when format in [:anthropic, "anthropic"], do: Anthropic

  def adapter_for(%{kind: kind}) when kind in [:ollama, "ollama"], do: Ollama

  # Copilot uses OpenAI-compatible API with extra headers
  def adapter_for(%{kind: kind}) when kind in [:"github-copilot", "github-copilot"], do: OpenAI

  # Custom providers with openai/anthropic-compatible APIs
  def adapter_for(%{api_format: format}) when format in [:custom, "custom"], do: OpenAI
end
