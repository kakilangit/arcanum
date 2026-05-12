defmodule Arcanum.Gateway do
  @moduledoc """
  Single entry point for all inference calls.

  Pipeline: auth → profile resolution → adapter → normalizer.

  Callers never touch adapters, profiles, or normalizers directly.

  ## Options

  All public functions accept an `opts` keyword list:
  - `:adapter` — override the adapter module (testing)
  - `:profile_overrides` — map of `ModelProfile` fields (highest priority)
  """

  alias Arcanum
  alias Arcanum.Auth
  alias Arcanum.{Intent, MediaIntent, MediaResponse, ModelProfile.Resolver, Response}
  alias Arcanum.Response.Normalizer

  @doc """
  Synchronous chat completion.
  """
  @spec chat(map(), Intent.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def chat(provider, %Intent{} = intent, opts \\ []) do
    adapter = Keyword.get(opts, :adapter) || Arcanum.adapter_for(provider)
    profile = resolve_profile(provider, intent.model, opts)
    provider = resolve_auth(provider)

    case adapter.chat(provider, intent, profile) do
      {:ok, response} -> {:ok, Normalizer.normalize(response, profile)}
      error -> error
    end
  end

  @doc """
  Streaming chat completion.
  """
  @spec stream(map(), Intent.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(provider, %Intent{} = intent, opts \\ []) do
    adapter = Keyword.get(opts, :adapter) || Arcanum.adapter_for(provider)
    profile = resolve_profile(provider, intent.model, opts)
    provider = resolve_auth(provider)
    adapter.stream(provider, intent, profile)
  end

  @doc """
  Lists available models from the provider.
  """
  @spec list_models(map()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(provider) do
    adapter = Arcanum.adapter_for(provider)
    provider = resolve_auth(provider)
    adapter.list_models(provider)
  end

  @doc """
  Generates embeddings for the given text input.
  """
  @spec embed(map(), String.t(), String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(provider, model, input) do
    adapter = Arcanum.adapter_for(provider)
    provider = resolve_auth(provider)

    if function_exported?(adapter, :embed, 3) do
      apply(adapter, :embed, [provider, model, input])
    else
      {:error, :not_supported}
    end
  end

  @doc """
  Generates images via the provider's image generation API.
  """
  @spec generate_image(map(), MediaIntent.t(), keyword()) ::
          {:ok, MediaResponse.t()} | {:error, term()}
  def generate_image(provider, %MediaIntent{} = intent, opts \\ []) do
    adapter = Keyword.get(opts, :adapter) || Arcanum.adapter_for(provider)
    profile = resolve_profile(provider, intent.model, opts)
    provider = resolve_auth(provider)

    if function_exported?(adapter, :generate_image, 3) do
      apply(adapter, :generate_image, [provider, intent, profile])
    else
      {:error, :not_supported}
    end
  end

  @doc """
  Generates videos via the provider's video generation API.
  """
  @spec generate_video(map(), MediaIntent.t(), keyword()) ::
          {:ok, MediaResponse.t()} | {:error, term()}
  def generate_video(provider, %MediaIntent{} = intent, opts \\ []) do
    adapter = Keyword.get(opts, :adapter) || Arcanum.adapter_for(provider)
    profile = resolve_profile(provider, intent.model, opts)
    provider = resolve_auth(provider)

    if function_exported?(adapter, :generate_video, 3) do
      apply(adapter, :generate_video, [provider, intent, profile])
    else
      {:error, :not_supported}
    end
  end

  defp resolve_profile(provider, model, opts) do
    overrides = Keyword.get(opts, :profile_overrides)
    Resolver.resolve(provider.kind, model, overrides)
  end

  defp resolve_auth(%{kind: "github-copilot"} = provider) do
    extra = Auth.Copilot.copilot_headers(Map.get(provider, :api_key, ""))
    Map.put(provider, :extra_headers, extra)
  end

  defp resolve_auth(provider), do: provider
end
