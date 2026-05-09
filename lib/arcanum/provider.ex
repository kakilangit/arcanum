defmodule Arcanum.Provider do
  @moduledoc """
  Behaviour for LLM inference providers.

  Each adapter (Ollama, OpenAI, Anthropic, etc.) implements this behaviour
  to provide a uniform interface for chat completion and model listing.

  Adapters receive a `ModelProfile` that declares model capabilities upfront.
  All provider/model-specific serialization decisions are driven by the profile —
  no runtime detection, no retry-on-error branching.
  """

  alias Arcanum.{Intent, ModelProfile, Response}

  @type stream_event :: {:data, Response.t()} | {:error, term()} | :done

  @doc """
  Sends a chat completion request and returns the full response.
  """
  @callback chat(provider :: map(), intent :: Intent.t(), profile :: ModelProfile.t()) ::
              {:ok, Response.t()} | {:error, term()}

  @doc """
  Sends a streaming chat completion request.

  Returns a stream of `{:data, response}` events, terminated by `:done`.
  """
  @callback stream(provider :: map(), intent :: Intent.t(), profile :: ModelProfile.t()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Lists available models from the provider.
  """
  @callback list_models(provider :: map()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Generates embeddings for the given text input.
  """
  @callback embed(provider :: map(), model :: String.t(), input :: String.t()) ::
              {:ok, [float()]} | {:error, term()}

  @optional_callbacks [embed: 3]
end
