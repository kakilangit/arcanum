defmodule Arcanum.Response do
  @moduledoc """
  Canonical response struct from inference calls.

  Normalizes provider responses into a uniform shape so that
  callers don't need to handle provider-specific formats.
  """

  @type tool_call :: %{
          id: String.t(),
          function: %{
            name: String.t(),
            arguments: String.t()
          }
        }

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @type t :: %__MODULE__{
          content: String.t() | nil,
          thinking: String.t() | nil,
          tool_calls: [tool_call()] | nil,
          usage: usage() | nil,
          finish_reason: String.t() | nil
        }

  defstruct [:content, :thinking, :tool_calls, :usage, :finish_reason]
end
