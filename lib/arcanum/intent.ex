defmodule Arcanum.Intent do
  @moduledoc """
  Canonical request struct for inference calls.

  Normalizes the request format across all providers so that the
  adapter layer handles provider-specific serialization.
  """

  @type message :: %{role: String.t(), content: String.t()}

  @type tool :: %{
          type: String.t(),
          function: %{
            name: String.t(),
            description: String.t(),
            parameters: map()
          }
        }

  @type t :: %__MODULE__{
          messages: [message()],
          model: String.t(),
          tools: [tool()] | nil,
          temperature: float() | nil,
          max_tokens: pos_integer() | nil,
          context_length: pos_integer() | nil
        }

  @enforce_keys [:messages, :model]
  defstruct [:messages, :model, :tools, :temperature, :max_tokens, :context_length]
end
