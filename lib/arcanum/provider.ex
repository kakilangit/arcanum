defmodule Arcanum.Provider do
  @moduledoc """
  Behaviour for inference provider adapters.

  Each adapter (Ollama, OpenAI, Anthropic, etc.) implements this behaviour
  to provide a uniform interface for chat completion, model listing,
  embeddings, and media generation.

  All provider/model-specific serialization decisions are driven by `ModelProfile`.

  ## Usage

      use Arcanum.Provider

  Optional callbacks (`embed/3`, `generate_image/3`, `generate_video/3`) return
  `{:error, :not_supported}` by default. Override only what the adapter supports.
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

  @doc """
  Generates images from a text prompt.
  """
  @callback generate_image(
              provider :: map(),
              intent :: Intent.t(),
              profile :: ModelProfile.t()
            ) ::
              {:ok, Response.t()} | {:error, term()}

  @doc """
  Generates videos from a text prompt.
  """
  @callback generate_video(
              provider :: map(),
              intent :: Intent.t(),
              profile :: ModelProfile.t()
            ) ::
              {:ok, Response.t()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Arcanum.Provider

      @impl Arcanum.Provider
      def embed(_provider, _model, _input), do: {:error, :not_supported}

      @impl Arcanum.Provider
      def generate_image(_provider, _intent, _profile), do: {:error, :not_supported}

      @impl Arcanum.Provider
      def generate_video(_provider, _intent, _profile), do: {:error, :not_supported}

      defoverridable embed: 3, generate_image: 3, generate_video: 3
    end
  end
end
