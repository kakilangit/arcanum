defmodule Arcanum.Response do
  @moduledoc """
  Canonical response struct from all inference calls.

  Content is always a list of typed blocks — symmetric with `Intent`.

  ## Chat Response

      %Response{content: [%{type: :text, text: "Hello!"}]}

  ## Streaming Delta

      %Response{content: [%{type: :text, text: "chunk"}]}

  ## Media Response

      %Response{
        content: [
          %{type: :image, data: <<...>>, content_type: "image/png", revised_prompt: "..."}
        ]
      }
  """

  alias Arcanum.Intent

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
          content: [Intent.content_block()] | nil,
          thinking: String.t() | nil,
          tool_calls: [tool_call()] | nil,
          usage: usage() | nil,
          finish_reason: String.t() | nil
        }

  defstruct [:content, :thinking, :tool_calls, :usage, :finish_reason]

  @doc """
  Extracts all text from response content blocks, joined by newline.
  Returns nil if content is nil or contains no text blocks.
  """
  @spec text(t()) :: String.t() | nil
  def text(%__MODULE__{content: nil}), do: nil
  def text(%__MODULE__{content: []}), do: nil

  def text(%__MODULE__{content: blocks}) do
    result = Intent.to_text(blocks)
    if result == "", do: nil, else: result
  end
end
