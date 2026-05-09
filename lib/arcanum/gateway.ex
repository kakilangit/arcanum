defmodule Arcanum.Gateway do
  @moduledoc """
  Single entry point for all inference calls.

  Pipeline: adapter (wire protocol) → normalizer (profile-driven post-processing).

  Callers never touch adapters, profiles, or normalizers directly.
  """

  alias Arcanum
  alias Arcanum.{Intent, ModelProfile.Resolver, Response}
  alias Arcanum.Response.Normalizer

  @doc """
  Synchronous chat completion.
  Accepts optional `adapter` override for testing.
  """
  @spec chat(map(), Intent.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def chat(provider, %Intent{} = intent, opts \\ []) do
    adapter = Keyword.get(opts, :adapter) || Arcanum.adapter_for(provider)
    profile = Resolver.resolve(provider.kind, intent.model)

    case adapter.chat(provider, intent, profile) do
      {:ok, response} -> {:ok, Normalizer.normalize(response, profile)}
      error -> error
    end
  end

  @doc """
  Streaming chat completion.

  Returns a normalized stream. Each delta has content fallback applied.
  The caller is responsible for merging deltas; the final merged response
  should be passed through `Normalizer.normalize/2` for tool-call extraction.
  """
  @spec stream(map(), Intent.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(provider, %Intent{} = intent, opts \\ []) do
    adapter = Keyword.get(opts, :adapter) || Arcanum.adapter_for(provider)
    profile = Resolver.resolve(provider.kind, intent.model)

    case adapter.stream(provider, intent, profile) do
      {:ok, stream} ->
        {:ok, stream}

      error ->
        error
    end
  end

  @doc """
  Lists available models from the provider.
  """
  @spec list_models(map()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(provider) do
    adapter = Arcanum.adapter_for(provider)
    adapter.list_models(provider)
  end

  @doc """
  Generates embeddings.
  """
  @spec embed(map(), String.t(), String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(provider, model, input) do
    adapter = Arcanum.adapter_for(provider)
    do_embed(adapter, provider, model, input)
  end

  defp do_embed(adapter, provider, model, input) do
    if function_exported?(adapter, :embed, 3) do
      adapter.embed(provider, model, input)
    else
      {:error, :embeddings_not_supported}
    end
  end
end
